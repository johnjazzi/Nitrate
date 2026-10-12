# Edge-grain benchmark

The isolated benchmark runs the production `pass2_grain` Metal kernel over a
3840×2160 RGBA16Float edge image with the shipped `grain3d.raw` volume and the
production BGRA8Unorm output format. It records GPU command-buffer duration for
boost 0 and boost 3, then checks that the paired output delta stays at the
transition. The report includes warm-up count, sample count, device name,
median, range, and the numerical regression.

Run it by itself, outside other GPU-heavy work:

```sh
TEST_RUNNER_GRAIN_BENCHMARK=1 \
TEST_RUNNER_GRAIN_BENCHMARK_OUTPUT="$PWD/.pi/tmp/edge-grain-benchmark-2026-10-12.md" \
xcodebuild test \
  -project FilmEmulation.xcodeproj \
  -scheme RenderCLI \
  -destination 'platform=macOS' \
  '-only-testing:RenderCLITests/GrainShadowTests/isolatedFourKEdgeBoostBenchmark()'
```

The test uses five alternating warm-up dispatches and twenty serial timed
dispatches per setting. Reported GPU load limitations are specific to the run;
the benchmark does not claim negligible overhead on other devices.

The `()` suffix is part of the Swift Testing function identifier accepted by
Xcode's `target/type/function` test selector. Xcode strips the `TEST_RUNNER_`
prefix and forwards those values to the test process; ordinary shell variables
are not reliably present in that process. The test rejects missing or invalid
GPU timestamps and reports the median timing delta and percentage overhead.
