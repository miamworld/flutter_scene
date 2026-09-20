// Covers the argument checks of EnvironmentMap.fromPrefilteredRadianceAtlas.
// The rest of the factory is one createTexture/overwrite pair and needs a
// device, so it is not exercised here (the same split as
// environment_ktx2_test.dart).

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const width = kPrefilterBandWidth;
  const height = kPrefilterBandHeight * kPrefilterBandCount;

  test('rejects a texel count that does not match the dimensions', () {
    expect(
      () => EnvironmentMap.fromPrefilteredRadianceAtlas(
        halfFloatTexels: Uint16List(width * height * 4 - 4),
        width: width,
        height: height,
      ),
      throwsA(
        isArgumentError.having(
          (e) => e.message,
          'message',
          contains('half-float texels'),
        ),
      ),
    );
  });

  test('rejects an atlas that is not one row block per roughness band', () {
    expect(
      () => EnvironmentMap.fromPrefilteredRadianceAtlas(
        halfFloatTexels: Uint16List(width * kPrefilterBandHeight * 4),
        width: width,
        height: kPrefilterBandHeight,
      ),
      throwsA(
        isArgumentError.having(
          (e) => e.message,
          'message',
          contains('bands of'),
        ),
      ),
    );
  });
}
