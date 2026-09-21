import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:vector_math/vector_math.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

int _getNextPowerOfTwoSize(int x) {
  if (x == 0) {
    return 1;
  }

  --x;

  x |= x >> 1;
  x |= x >> 2;
  x |= x >> 4;
  x |= x >> 8;
  x |= x >> 16;

  return x + 1;
}

/// The edge length of the square joints texture holding [jointCount] matrices.
///
/// One matrix spans four consecutive texels, and the vertex shader reads all
/// four from the same row, so the edge must be a multiple of four; the next
/// power of two at or above 4 satisfies both that and GPU sizing.
int _jointsTextureEdge(int jointCount) {
  // 1 matrix = 16 floats, 1 texel = 4 floats, so 4 texels per joint.
  final int requiredTexels = jointCount * 4;
  return max(4, _getNextPowerOfTwoSize(sqrt(requiredTexels).ceil()));
}

/// A skeletal binding used by skinned meshes for animation.
///
/// A `Skin` pairs an ordered list of [joints] (scene-graph [Node]s acting as
/// bones) with the [inverseBindMatrices] that transform a mesh from model
/// space into each joint's rest-pose local space. The vertex shader
/// combines these with the joints' current transforms to deform the mesh.
///
/// `Skin` instances are usually populated by an importer rather than
/// constructed directly. They are attached to the mesh-bearing [Node] via
/// [Node.skin].
/// {@category Geometry}
base class Skin {
  /// The bone nodes referenced by this skin, in shader-binding order.
  ///
  /// Entries may be `null` when [Node.clone] is unable to relocate a joint
  /// in the cloned subtree; the renderer treats null joints as identity
  /// transforms.
  final List<Node?> joints = [];

  /// The inverse bind matrix for each joint, transforming a vertex from
  /// model space into the joint's rest-pose local space.
  ///
  /// Parallel to [joints]: `inverseBindMatrices[i]` corresponds to
  /// `joints[i]`.
  final List<Matrix4> inverseBindMatrices = [];

  /// Pool of joints textures, recycled once the GPU is known to be done
  /// with them.
  ///
  /// A joints texture is uploaded with `Texture.overwrite`, which submits a
  /// buffer-to-image copy in its own command buffer, and is then read by the
  /// **vertex** stage of the draws that follow. Impeller's Vulkan backend
  /// makes that copy visible to the fragment stage only --
  /// `BlitPassVK::OnCopyBufferToTextureCommand` ends the copy with a barrier
  /// whose `dst_stage` is `eFragmentShader`, and `RenderPassVK::BindResource`
  /// adds no barrier of its own for a sampled texture -- so a vertex shader
  /// may read the texture before, or while, the copy executes. On a
  /// tile-based GPU that shows up as a skinned mesh drawn with a stale or
  /// half-written skeleton: a strip of it offset from the rest, or the whole
  /// mesh flung across the screen.
  ///
  /// Neither a deeper ring nor a fresh texture per frame fixes that (both
  /// make the stale content *older*, so the artifact gets worse). The only
  /// thing that does is to sample a texture whose upload is known to have
  /// finished, so this pool hands out the newest slot whose upload has been
  /// observed complete through [rendererSubmissions], and writes into a slot
  /// that is neither pending nor still readable by work in flight. The cost
  /// is that the skeleton a frame draws with is one to two frames old.
  static const int _maxJointsTextures = 4;
  final List<_JointsSlot> _jointsSlots = [];

  /// Slots in upload order; the last one holds this frame's matrices.
  final List<_JointsSlot> _jointsUploads = [];

  /// The slot handed to the renderer for the current frame, and the one
  /// before it (for [getPreviousJointsTexture]).
  _JointsSlot? _currentSlot;
  _JointsSlot? _previousSlot;
  int _jointsTextureDimension = 0;

  /// Computes the joint matrices for the current frame and uploads them as
  /// a square `RGBA32F` GPU texture.
  ///
  /// Each joint occupies four texels (one matrix). The texture's edge
  /// length is rounded up to the next power of two, with a floor of four so
  /// a matrix never straddles a row; unused slots are initialized to identity.
  ///
  /// The returned texture is the most recent one whose upload the GPU has
  /// finished (see [_maxJointsTextures]); before any upload has been
  /// observed complete -- the first frames of a scene -- the texture just
  /// written is returned.
  ///
  /// The companion [getTextureWidth] returns the same edge length so the
  /// vertex shader can index into the texture.
  gpu.Texture getJointsTexture() {
    final int dimensionSize = _jointsTextureEdge(joints.length);

    // Drop the pool if the texture size changed (joint count is fixed
    // after construction, so this normally never triggers).
    if (dimensionSize != _jointsTextureDimension) {
      _jointsSlots.clear();
      _jointsUploads.clear();
      _currentSlot = null;
      _previousSlot = null;
      _jointsTextureDimension = dimensionSize;
    }

    // Everything submitted since the last call may have read the slot handed
    // out then, so that is the watermark its contents must outlive.
    _currentSlot?.readStamp = rendererSubmissions.latestSubmission;
    final int completed = rendererSubmissions.completedThrough;

    final _JointsSlot? target = _acquireJointsSlot(completed, dimensionSize);
    if (target != null) {
      target.texture.overwrite(_packJointMatrices(dimensionSize));
      // `Texture.overwrite` submits its own command buffer, untracked; the
      // next submission the renderer records comes after it, so that
      // submission completing implies this copy has landed.
      target.uploadStamp = rendererSubmissions.latestSubmission + 1;
      _jointsUploads
        ..remove(target)
        ..add(target);
    }

    // The newest slot whose upload the GPU has finished. Falling back to the
    // freshest upload only happens before any completion has been observed.
    _JointsSlot? ready;
    for (final slot in _jointsUploads) {
      if (slot.uploadStamp <= completed) ready = slot;
    }
    final _JointsSlot result = ready ?? _jointsUploads.last;
    if (!identical(result, _currentSlot)) {
      _previousSlot = _currentSlot;
      _currentSlot = result;
    }
    return result.texture;
  }

  /// A slot safe to write this frame: not the one being drawn with, with no
  /// upload still pending and no submission that may still read it in
  /// flight. Returns null when every slot is busy (the frame then re-uses
  /// the matrices it already uploaded).
  _JointsSlot? _acquireJointsSlot(int completed, int dimensionSize) {
    for (final slot in _jointsSlots) {
      if (identical(slot, _currentSlot)) continue;
      if (slot.uploadStamp > completed) continue;
      if (slot.readStamp > completed) continue;
      return slot;
    }
    if (_jointsSlots.length >= _maxJointsTextures) return null;
    final slot = _JointsSlot(
      gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        dimensionSize,
        dimensionSize,
        format: gpu.PixelFormat.r32g32b32a32Float,
      ),
    );
    _jointsSlots.add(slot);
    return slot;
  }

  /// This frame's joint matrices, laid out four texels per joint.
  ByteData _packJointMatrices(int dimensionSize) {
    // 64 bytes per matrix. 4 bytes per pixel.
    final Float32List jointMatrixFloats = Float32List(
      dimensionSize * dimensionSize * 4,
    );
    // Initialize with identity matrices.
    for (int i = 0; i < jointMatrixFloats.length; i += 16) {
      jointMatrixFloats[i] = 1.0;
      jointMatrixFloats[i + 5] = 1.0;
      jointMatrixFloats[i + 10] = 1.0;
      jointMatrixFloats[i + 15] = 1.0;
    }

    for (int jointIndex = 0; jointIndex < joints.length; jointIndex++) {
      final Node? joint = joints[jointIndex];
      // A null joint (Node.clone couldn't relocate it) keeps the
      // pre-initialized identity slot.
      if (joint == null) continue;

      // glTF skinning: the joint matrix is the joint's full global
      // transform times its inverse bind matrix. globalTransform walks
      // every ancestor, so transforms on non-joint nodes between the
      // joints and the scene root (e.g. a skeleton root carrying the
      // model's Z-up-to-Y-up correction) are included, as is the
      // scene-root flip. The inverse bind matrix takes a vertex from
      // model space into the joint's rest-pose space; the global
      // transform then places it by the joint's current pose.
      //
      // The shader applies this matrix directly, so the mesh node's own
      // transform must not be applied again -- SkinnedGeometry.bind
      // passes an identity model transform.
      final Matrix4 matrix =
          joint.globalTransform * inverseBindMatrices[jointIndex];
      final floatOffset = jointIndex * 16;
      jointMatrixFloats.setRange(floatOffset, floatOffset + 16, matrix.storage);
    }
    return jointMatrixFloats.buffer.asByteData();
  }

  /// The edge length, in texels, of the joints texture produced by
  /// [getJointsTexture].
  int getTextureWidth() => _jointsTextureEdge(joints.length);

  /// The previous frame's joints texture, or the current one on the first
  /// frame.
  gpu.Texture getPreviousJointsTexture() =>
      (_previousSlot ?? _currentSlot ?? _jointsUploads.last).texture;
}

/// One pooled joints texture and the submission watermarks that say when it
/// is safe to write to, and when its contents are on the GPU.
class _JointsSlot {
  _JointsSlot(this.texture);

  final gpu.Texture texture;

  /// The submission whose completion implies this slot's upload landed.
  int uploadStamp = 0;

  /// The highest submission that may still read this slot as a draw source.
  int readStamp = 0;
}
