/// On-device "does this look like a plant?" hint built from ML Kit image labels.
///
/// ADVISORY ONLY. ML Kit's pretrained labeller is coarse: it can say a photo
/// contains plant-like things, not that it shows a sapling, a mature tree, or a
/// planting. Nothing here accepts, rejects or rewards a submission, and no
/// accuracy has been measured on Dhara photos (there is no labelled set yet).
/// The numbers below are uncalibrated starting points.
enum PlantHint {
  /// Vegetation labels with decent confidence.
  plantLikely,

  /// A screen, or a confident reading of something that is not vegetation.
  unrelatedSuspected,

  /// Weak or mixed evidence, or nothing recognised.
  uncertain,

  /// The labeller could not run.
  analysisUnavailable,
}

enum SceneCategory { plant, tree, vegetation, naturalOutdoor }

class ScoredLabel {
  const ScoredLabel(this.label, this.confidence);

  final String label;
  final double confidence;
}

class SceneAnalysis {
  const SceneAnalysis({
    required this.hint,
    this.categories = const {},
    this.topLabels = const [],
  });

  final PlantHint hint;
  final Set<SceneCategory> categories;

  /// Up to three labels by confidence, for showing "looks like: ...".
  final List<String> topLabels;

  static const unavailable = SceneAnalysis(hint: PlantHint.analysisUnavailable);
}

class SceneLimits {
  static const plantLikelyAt = 0.55;
  static const screenAt = 0.6;
  static const confidentOtherAt = 0.7;
  static const weakAt = 0.4; // ML Kit labeller is configured with this floor
}

const _treeLabels = {
  'tree',
  'woody plant',
  'palm tree',
  'forest',
  'jungle',
  'trunk',
  'branch',
};
const _plantLabels = {
  'plant',
  'leaf',
  'flower',
  'houseplant',
  'flowerpot',
  'shrub',
  'sapling',
  'fern',
  'moss',
  'bud',
  'flora',
  'bamboo',
  'petal',
};
const _vegetationLabels = {
  'grass',
  'lawn',
  'vegetation',
  'garden',
  'plantation',
  'grassland',
  'crop',
  'field',
  'agriculture',
  'soil',
};
const _naturalLabels = {
  'nature',
  'sky',
  'cloud',
  'landscape',
  'natural landscape',
  'mountain',
  'hill',
  'water',
  'lake',
  'river',
  'sunset',
  'sunrise',
  'rock',
};
const _screenLabels = {
  'screenshot',
  'monitor',
  'television',
  'computer',
  'laptop',
  'display',
  'mobile phone',
  'screen',
  'website',
  'text',
  'document',
  'paper',
};

SceneAnalysis classifyScene(List<ScoredLabel> labels) {
  if (labels.isEmpty) return const SceneAnalysis(hint: PlantHint.uncertain);

  final categories = <SceneCategory>{};
  var plantScore = 0.0; // best of plant, tree, vegetation
  var naturalScore = 0.0;
  var screenScore = 0.0;
  var otherScore = 0.0; // confident about something that is none of the above

  for (final l in labels) {
    final name = l.label.toLowerCase().trim();
    final c = l.confidence;
    var known = false;
    if (_treeLabels.contains(name)) {
      categories.add(SceneCategory.tree);
      plantScore = c > plantScore ? c : plantScore;
      known = true;
    }
    if (_plantLabels.contains(name)) {
      categories.add(SceneCategory.plant);
      plantScore = c > plantScore ? c : plantScore;
      known = true;
    }
    if (_vegetationLabels.contains(name)) {
      categories.add(SceneCategory.vegetation);
      plantScore = c > plantScore ? c : plantScore;
      known = true;
    }
    if (_naturalLabels.contains(name)) {
      categories.add(SceneCategory.naturalOutdoor);
      naturalScore = c > naturalScore ? c : naturalScore;
      known = true;
    }
    if (_screenLabels.contains(name)) {
      screenScore = c > screenScore ? c : screenScore;
      known = true;
    }
    if (!known && c > otherScore) otherScore = c;
  }

  final sorted = [...labels]
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  final top = [for (final l in sorted.take(3)) l.label];

  PlantHint hint;
  if (screenScore >= SceneLimits.screenAt && screenScore > plantScore) {
    hint = PlantHint.unrelatedSuspected;
  } else if (plantScore >= SceneLimits.plantLikelyAt) {
    hint = PlantHint.plantLikely;
  } else if (plantScore > 0 || naturalScore >= SceneLimits.weakAt) {
    hint = PlantHint.uncertain;
  } else if (otherScore >= SceneLimits.confidentOtherAt) {
    hint = PlantHint.unrelatedSuspected;
  } else {
    hint = PlantHint.uncertain;
  }

  return SceneAnalysis(hint: hint, categories: categories, topLabels: top);
}
