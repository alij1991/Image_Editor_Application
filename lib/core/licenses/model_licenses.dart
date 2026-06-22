import 'package:flutter/foundation.dart';

/// XVI.130 (A6) — attribution for the on-device ML model WEIGHTS the app
/// ships or downloads.
///
/// Flutter's [LicenseRegistry] auto-collects the LICENSE files of every
/// Dart/Flutter package (incl. the native plugins onnxruntime / litert /
/// opencv_dart), and those appear in the in-app `showLicensePage`. But
/// raw model-weight assets aren't packages, so their licenses are NOT
/// collected automatically. This registers them so each shipped model
/// and its license is attributed in the same Licenses screen.
///
/// Call once from `main()`. Registration is lazy — the generator only
/// runs when the user opens the Licenses page.
///
/// Every model below was license-verified against its exact bundled /
/// downloaded provenance (see docs/release_audit_2026.md A9). The bar is
/// the model/weights license the author grants. Models whose *model*
/// license is non-commercial were dropped, not attributed: SegFormer
/// (NVIDIA-NC, A7), Harmonizer (CC-BY-NC-SA, A8); face-restore / RMBG /
/// RVM earlier (A1–A3).
void registerModelLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(_apachePackages, _apacheText);
    yield const LicenseEntryWithLineBreaks(_mitPackages, _mitText);
    yield const LicenseEntryWithLineBreaks(_bsdPackages, _bsdText);
    yield const LicenseEntryWithLineBreaks(_applePackages, _appleText);
  });
}

// ---------------------------------------------------------------------------
// Apache-2.0 models
// ---------------------------------------------------------------------------

const List<String> _apachePackages = <String>[
  'MediaPipe Selfie Segmentation (model)',
  'MediaPipe Face Detection / BlazeFace (model)',
  'MediaPipe Face Mesh (model)',
  'MediaPipe Selfie Multiclass (model)',
  'EfficientDet-Lite0 (model)',
  'Magenta Arbitrary Image Stylization (model)',
  'DeepLabV3 ADE20K / Pascal VOC (model)',
  'LaMa big-lama inpainting (model)',
  'MODNet portrait matting (model)',
  'MobileSAM (model)',
];

const String _apacheText = '''
The following on-device models are distributed under the Apache License, Version 2.0:

• MediaPipe Selfie Segmentation, Face Detection (BlazeFace), Face Mesh, Selfie Multiclass — Copyright Google LLC — https://github.com/google-ai-edge/mediapipe
• EfficientDet-Lite0 — Copyright The TensorFlow Authors / Google LLC — https://www.kaggle.com/models/tensorflow/efficientdet
• Magenta Arbitrary Image Stylization — Copyright The Magenta Authors / Google LLC — https://github.com/magenta/magenta
• DeepLabV3 (ADE20K, Pascal VOC) — Copyright The TensorFlow Authors — https://github.com/tensorflow/models
• LaMa (big-lama) — Copyright 2021 Samsung Research — https://github.com/advimman/lama
• MODNet — Copyright Zhanghan Ke et al. — https://github.com/ZHKKKe/MODNet
• MobileSAM — Copyright Kyung Hee University (Zhang et al.) — https://github.com/ChaoningZhang/MobileSAM

$_apacheLicenseBody''';

// ---------------------------------------------------------------------------
// MIT models
// ---------------------------------------------------------------------------

const List<String> _mitPackages = <String>[
  'MI-GAN inpainting (model)',
  'NAFNet deblur (model)',
  'BiRefNet-Lite background removal (model)',
];

const String _mitText = '''
The following on-device models are distributed under the MIT License:

• MI-GAN — Copyright (c) 2024 Picsart AI Research (PAIR) — https://github.com/Picsart-AI-Research/MI-GAN
• NAFNet — Copyright (c) 2022 megvii-model (Megvii Research) — https://github.com/megvii-research/NAFNet
• BiRefNet — Copyright (c) 2024 Peng Zheng (ZhengPeng7) — https://github.com/ZhengPeng7/BiRefNet

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';

// ---------------------------------------------------------------------------
// BSD-3-Clause models
// ---------------------------------------------------------------------------

const List<String> _bsdPackages = <String>[
  'DnCNN denoise — deepinv (model)',
  'Real-ESRGAN super-resolution (model)',
];

const String _bsdText = '''
The following on-device models are distributed under the BSD 3-Clause License:

• DnCNN (color denoise) — Copyright (c) 2023, deepinv — https://github.com/deepinv/deepinv
• Real-ESRGAN (x2, x4) — Copyright (c) 2021, Xintao Wang — https://github.com/xinntao/Real-ESRGAN

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.''';

// ---------------------------------------------------------------------------
// Apple ml-cvnets (MobileViT) — permissive, requires retaining the notice
// ---------------------------------------------------------------------------

const List<String> _applePackages = <String>[
  'MobileViT v2 (model)',
];

const String _appleText = '''
MobileViT v2 (Mehta & Rastegari, ICLR 2022) — Copyright (C) 2023 Apple Inc. All Rights Reserved. — https://github.com/apple/ml-cvnets

Distributed under the Apple Software License (a BSD-style permissive license; the model card's SPDX tag is "other"):

Apple grants you a personal, non-exclusive license, under Apple's copyrights in this original Apple software (the "Apple Software"), to use, reproduce, modify and redistribute the Apple Software, with or without modifications, in source and/or binary forms; provided that if you redistribute the Apple Software in its entirety and without modifications, you must retain this notice and the following text and disclaimers in all such redistributions of the Apple Software. Neither the name, trademarks, service marks or logos of Apple Inc. may be used to endorse or promote products derived from the Apple Software without specific prior written permission from Apple.

THE APPLE SOFTWARE IS PROVIDED BY APPLE ON AN "AS IS" BASIS. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.''';

// ---------------------------------------------------------------------------
// Shared Apache-2.0 license body (Apache License 2.0, January 2004).
// ---------------------------------------------------------------------------

const String _apacheLicenseBody = '''
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.

"You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this License.

"Work" shall mean the work of authorship, whether in Source or Object form, made available under the License.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work.

4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, provided that You meet the following conditions: (a) You must give any other recipients of the Work or Derivative Works a copy of this License; and (b) You must cause any modified files to carry prominent notices stating that You changed the files; and (c) You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work; and (d) If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file.

5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions.

6. Trademarks. This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides the Work on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

8. Limitation of Liability. In no event and under no legal theory shall any Contributor be liable to You for damages arising as a result of this License or out of the use or inability to use the Work.

9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License.

END OF TERMS AND CONDITIONS''';
