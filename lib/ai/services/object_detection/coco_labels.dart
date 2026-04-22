/// COCO 2017 object-detection label map used by the TensorFlow Hub
/// EfficientDet-Lite0 `detection-default` model we ship.
///
/// The model emits 0-based class indices into the 80-class COCO
/// labelmap — the one used by TensorFlow Hub's detection-default
/// variant (the int model's embedded labelmap, not the sparse 90-slot
/// "COCO 2017 mscoco complete label map" found in some model zoos).
///
/// This class is intentionally a pure value holder — no dependency
/// on any service or model file — so it can be consumed by scanner,
/// editor, or tests without pulling the rest of the object-detector
/// graph along.
class CocoLabels {
  CocoLabels._();

  /// English labels indexed by the model's class index (0-based,
  /// densely packed 0..79). Out-of-range indices return `null` from
  /// [labelFor].
  static const List<String> labels = <String>[
    'person',           // 0
    'bicycle',          // 1
    'car',              // 2
    'motorcycle',       // 3
    'airplane',         // 4
    'bus',              // 5
    'train',            // 6
    'truck',            // 7
    'boat',             // 8
    'traffic light',    // 9
    'fire hydrant',     // 10
    'stop sign',        // 11
    'parking meter',    // 12
    'bench',            // 13
    'bird',             // 14
    'cat',              // 15
    'dog',              // 16
    'horse',            // 17
    'sheep',            // 18
    'cow',              // 19
    'elephant',         // 20
    'bear',             // 21
    'zebra',            // 22
    'giraffe',          // 23
    'backpack',         // 24
    'umbrella',         // 25
    'handbag',          // 26
    'tie',              // 27
    'suitcase',         // 28
    'frisbee',          // 29
    'skis',             // 30
    'snowboard',        // 31
    'sports ball',      // 32
    'kite',             // 33
    'baseball bat',     // 34
    'baseball glove',   // 35
    'skateboard',       // 36
    'surfboard',        // 37
    'tennis racket',    // 38
    'bottle',           // 39
    'wine glass',       // 40
    'cup',              // 41
    'fork',             // 42
    'knife',            // 43
    'spoon',            // 44
    'bowl',             // 45
    'banana',           // 46
    'apple',            // 47
    'sandwich',         // 48
    'orange',           // 49
    'broccoli',         // 50
    'carrot',           // 51
    'hot dog',          // 52
    'pizza',            // 53
    'donut',            // 54
    'cake',             // 55
    'chair',            // 56
    'couch',            // 57
    'potted plant',     // 58
    'bed',              // 59
    'dining table',     // 60
    'toilet',           // 61
    'tv',               // 62
    'laptop',           // 63
    'mouse',            // 64
    'remote',           // 65
    'keyboard',         // 66
    'cell phone',       // 67
    'microwave',        // 68
    'oven',             // 69
    'toaster',          // 70
    'sink',             // 71
    'refrigerator',     // 72
    'book',             // 73
    'clock',            // 74
    'vase',             // 75
    'scissors',         // 76
    'teddy bear',       // 77
    'hair drier',       // 78
    'toothbrush',       // 79
  ];

  /// Return the English label for [classIndex] if the index is in
  /// range, otherwise null.
  static String? labelFor(int classIndex) {
    if (classIndex < 0 || classIndex >= labels.length) return null;
    return labels[classIndex];
  }

  // ---------------------------------------------------------------------
  // Named class constants for callers that want to reason about
  // specific categories without string comparison. Keep these in sync
  // with the labels list above.
  // ---------------------------------------------------------------------

  /// Person / human. Useful for smart-crop (people first) and
  /// portrait-specific features.
  static const int personClass = 0;

  /// Pet cat — smart-crop treats as high-priority subject.
  static const int catClass = 15;

  /// Pet dog — smart-crop treats as high-priority subject.
  static const int dogClass = 16;

  /// Document-adjacent COCO classes. The scanner's OpenCV seeder uses
  /// these as a region prior: if any fire, crop the contour search to
  /// their bbox instead of the whole frame.
  static const int laptopClass = 63;
  static const int tvClass = 62;
  static const int cellPhoneClass = 67;
  static const int bookClass = 73;

  /// The subset of classes the scanner's corner-seeder accepts as a
  /// document-region prior. `paper` has no dedicated COCO class — the
  /// best we can do is favour book/laptop/tv/cell-phone bboxes and
  /// fall back to the full frame otherwise.
  static const Set<int> scannerPriorClasses = <int>{
    bookClass,
    laptopClass,
    tvClass,
    cellPhoneClass,
  };

  /// Food-adjacent classes the smart-crop heuristic treats as a
  /// preferred subject when no person/pet is detected.
  static const Set<int> foodClasses = <int>{
    46, // banana
    47, // apple
    48, // sandwich
    49, // orange
    50, // broccoli
    51, // carrot
    52, // hot dog
    53, // pizza
    54, // donut
    55, // cake,
  };
}
