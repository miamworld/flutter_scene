import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

/// `Scene` skips building its default environment for a frame whose materials
/// all report that they never read it, so the answers here decide whether a
/// 48-pass radiance prefilter runs. The default must stay `true`: a custom
/// material can read `Lighting.environmentMap` in its own `bind`.
class _CustomMaterial extends Material {
  @override
  void bind(_, __, ___) {}
}

void main() {
  test('a custom material is assumed to sample the environment', () {
    expect(_CustomMaterial().usesSceneEnvironment, isTrue);
  });

  test('unlit materials do not sample the environment', () {
    expect(UnlitMaterial().usesSceneEnvironment, isFalse);
  });

  test('a physically based material samples the scene environment', () {
    // The `environment != null` case needs an `EnvironmentMap`, which needs a
    // GPU context, so it is not covered here.
    expect(PhysicallyBasedMaterial().usesSceneEnvironment, isTrue);
  });
}
