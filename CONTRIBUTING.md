# Contributing

## Commit messages

`type(scope): description`, in English, imperative, lower case after the colon,
no full stop, no trailers.

```
feat(ios): keep the coarse pyramid on screen while a level fills
fix(android): report zoom and tap in points, not pixels
docs: explain why the tile ladder is indexed by rung
```

Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `build`.

The scope is the part of the package the change lands in: `ios`, `android`,
`js`, `example`, `docs`. Leave it out when the change spans all of them.

Say what the change does, not what you did to the file. `fix(ios): stop the
double tap jumping` over `fix(ios): update PdfSurface.swift`.

## Before you commit

```sh
npm run verify
```

which is the typecheck plus both native test suites. The suites carry the
decision logic, not the drawing: page layout, the fit policy, zoom limits, the
tile ladder and which tiles a viewport asks for. They run without a device, so
there is no excuse for skipping them.

`npm run test:android` is broken at the moment, and with it `verify`. The
Kotlin tests need a Gradle project to run in, and until this package was
published that project was the app it was developed inside. The fix is an
example app in this repository, which the tests and the screenshots can both
run through; until it exists the Android suite has to be run from an app that
has the package linked, and iOS carries `verify` on its own.

If you touched anything under `src/specs`, run `npm run specs` as well and
commit the regenerated `nitrogen/` output alongside it. Generated files belong
in the same commit as the spec that produced them.

## Changing the native side

The two platforms answer to the same contract in `src/specs/PdfView.nitro.ts`,
and the numbers that decide behaviour are deliberately written twice, once in
`ios/PdfViewport.swift` and once in `android/.../PdfViewport.kt`. A change to
one is a change to both, with a test on both sides. Where the platforms have to
differ, say so in the README rather than letting the difference sit unexplained
in the source.

Native view props are all required, with a sentinel for "the viewer decides".
That is not a style choice, and `src/PdfView.tsx` explains why. Do not make one
optional.

## Pull requests

One subject per branch, rebase rather than merge, and the history stays
readable: a reviewer should be able to read the subjects alone and know what
happened.
