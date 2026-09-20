# Miamworld's mirror of `bdero/flutter_scene`

This repository is a **private mirror** of
[`bdero/flutter_scene`](https://github.com/bdero/flutter_scene). It exists so
Miamworld can carry patches to flutter_scene, consume them as a git dependency,
and review them as pull requests before proposing anything upstream.

**Nothing here is ever pushed to the upstream repository.** All pull requests in
this repository target this repository's `master`.

## Branches

| branch | what it is |
|---|---|
| `master` | **byte-identical to upstream `master`**. Every upstream branch and tag was mirrored as-is (`git push --mirror`, minus GitHub's read-only `refs/pull/*`). Do not commit here. |
| `miamworld/0.23.0-patched` | the branch apps consume: upstream tag `flutter_scene-0.23.0` plus our eight library fixes, one clean commit each, released as the tag **`flutter_scene-0.23.0+miamworld.1`**. |
| `fix/*` | one branch per fix, ported onto `master` (upstream's unreleased 0.24.0), each the head of a **draft PR** written for the upstream author. |
| `miamworld-notes` | this file. |

Upstream's default branch is `master`; there is no `main`. This mirror keeps that.

## Consuming it

```yaml
dependency_overrides:
  flutter_scene:
    git:
      url: git@github.com:miamworld/flutter_scene.git
      ref: flutter_scene-0.23.0+miamworld.1
      path: packages/flutter_scene
```

## The patches, and where they came from

All eight came out of one investigation: a `SceneView` page in the Miamworld app
took 3.15 s to reach a steady animating scene on a Samsung Galaxy A16 (SM-A165F,
Android 16, Mali-G57 MC1, Impeller **OpenGLES**, UI and platform task runners
merged), with 1.7 s of that spent with the display completely frozen. ~50 traced
device runs, Perfetto plus `dart:developer` timeline instrumentation. After the
patches (and two app-side changes that are not in this repository) the same page
reaches a steady scene in ~1.06 s with no display stall over 143 ms.

Each commit message on `miamworld/0.23.0-patched` carries its own mechanism and
numbers; `packages/flutter_scene/CHANGELOG.md` summarises them under
`0.23.0+miamworld.1`.

Four findings from the same investigation belong to the Flutter engine rather
than to flutter_scene, and are written up separately for `flutter/flutter`:
`RenderPass::GetOrCreatePipeline` blocking the UI thread on GLES; no
GPU-completion signal in `dart:gpu`; `SupportsFramebufferRenderMipmap()`
hard-coded false on GLES; and a `devicePrivate` readback that is not ordered
after the draw that filled it.

## Keeping up with upstream

```sh
git remote add upstream https://github.com/bdero/flutter_scene.git
git remote set-url --push upstream DISABLED    # never push upstream
git fetch upstream
git push origin 'refs/remotes/upstream/*:refs/heads/*'   # review before doing this
```

The push URL for `upstream` is deliberately set to `DISABLED` in the working
clone so a stray `git push upstream` fails instead of reaching bdero's repo.
