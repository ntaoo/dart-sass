library sass.transformer;

import 'dart:async';
import 'package:barback/barback.dart';
import 'package:path/path.dart';
import 'sass.dart';

/// Transformer used by `pub build` and `pub serve` to convert Sass-files to CSS.
class SassTransformer extends Transformer implements DeclaringTransformer {
  final BarbackSettings settings;
  final TransformerOptions options;
  final Sass _sass;

  SassTransformer(BarbackSettings settings, this._sass) :
    settings = settings,
    options = new TransformerOptions.parse(settings.configuration);

  SassTransformer.asPlugin(BarbackSettings settings) :
    this(settings, new Sass());

  Future<bool> isPrimary(AssetId input) {
    // We consider all .scss and .sass files primary although in reality we process only
    // the ones that don't start with an underscore. This way we can call consumePrimary()
    // for all files and they don't end up in the build-directory.
    var extension = posix.extension(input.path);
    var primary = extension == '.sass' || extension == '.scss';

    return new Future.value(primary);
  }

  /// Reads all the imports of module so that Barback realizes that we depend on them.
  ///
  /// When Barback calls the transformer to process foo.scss, it will keep track of all
  /// read-calls so it knows which files foo.scss is dependent on. So if foo.scss
  /// imports bar.scss (and therefore we perform dummy read on bar.scss as well),
  /// Barback knows that if bar.scss changes, it will need to recompile foo.scss.
  /// This doesn't matter when executing a batch build with "pub build", but it's
  /// really important with "pub serve".
  Future _readImportsRecursively(Transform transform, AssetId assetId) =>
    transform.readInputAsString(assetId).then((source) {
      var imports = Sass.resolveImportsFromSource(source);

      if (options.compass) {
        imports = _excludeCompassImports(imports);
      }

      return Future.wait(imports.map((module) {
        var name = module.contains('.') ? module : "_$module${assetId.extension}";
        var path = posix.join(posix.dirname(assetId.path), name);
        return _readImportsRecursively(transform, new AssetId(assetId.package, path));
      }));
    });

  Iterable<String> _excludeCompassImports(Iterable<String> imports) {
    return imports.where((import) => !import.startsWith("compass"));
  }

  Future apply(Transform transform) {
    AssetId primaryAssetId = transform.primaryInput.id;

    if (!options.copySources)
      transform.consumePrimary();

    if (posix.basename(primaryAssetId.path).startsWith('_'))
        return new Future.value();

    return _readImportsRecursively(transform, primaryAssetId).then((_) {
      _sass.executable = options.executable;
      _sass.style = options.style;
      _sass.compass = options.compass;
      _sass.lineNumbers = options.lineNumbers;

      if (primaryAssetId.extension == '.scss') {
        _sass.scss = true;
      }

      _sass.loadPath.add(posix.dirname(primaryAssetId.path));

      return transform.primaryInput.readAsString().then((content) =>
        _sass.transform(content).then((output) {
          var newId = primaryAssetId.changeExtension('.css');
          transform.addOutput(new Asset.fromString(newId, output));
        }));
    }).catchError((SassException e) {
      transform.logger.error("error: ${e.message}");
    }, test: (e) => e is SassException);
  }

  Future declareOutputs(DeclaringTransform transform) {
    AssetId primaryAssetId = transform.primaryId;
    transform.declareOutput(primaryAssetId.changeExtension('.css'));

    return new Future.value();
  }
}

class TransformerOptions {
  final String executable;
  final String style;
  final bool compass;
  final bool lineNumbers;
  final bool copySources;

  TransformerOptions({String this.executable, String this.style, bool this.compass, bool this.lineNumbers, bool this.copySources});

  factory TransformerOptions.parse(Map configuration) {
    config(key, defaultValue) {
      var value = configuration[key];
      return value != null ? value : defaultValue;
    }

    return new TransformerOptions(
        executable: config("executable", "sass"),
        style: config("style", null),
        compass: config("compass", false),
        lineNumbers: config("line-numbers", false),
        copySources: config("copy-sources", false));
  }
}
