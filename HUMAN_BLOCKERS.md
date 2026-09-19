# Radiance (Java side) – human blockers & handoff (written 2026-09-18, untracked, not committed)

## TL;DR
The Java mod **compiles and builds** (JDK 21). JNI headers are generated, which unblocks MCVR's B2. Nothing is runnable yet: the jar has no `libcore.so` / shaders (they come from the MCVR build), and that build needs sudo packages. No code was changed.

## 1. Done (verify: one command)
```
cd ~/Projects/Repos/Minecraft-Radiance/Radiance
JAVA_HOME=/tmp/claude-1000/-home-anon-Projects-Repos-Minecraft-Radiance-Radiance/d3d4c0af-e7df-4c5b-95ed-3bbfc6d93f79/scratchpad/jdk21 ./gradlew build
```
- Result: BUILD SUCCESSFUL, `build/libs/Radiance-0.1.5-alpha-fabric-1.21.4.jar`.
- **Root cause of the earlier Gradle failure** (mentioned as a risk in `../MCVR/HUMAN_BLOCKERS.md` B2): system `java` is JDK 25; Gradle 8.14.1 fails with `Unsupported class file major version 69`. Only JDK 25 and Temurin 11 are installed, neither works. I downloaded Temurin 21 (Adoptium) into the session scratchpad (`.../scratchpad/jdk21`). It is outside the repo, and nothing was installed system-wide.
- JNI headers now exist in `src/main/native/include/` (16 files, git-ignored by `include/`). **`../MCVR` B2 is therefore done**, as long as that directory stays.
- `git status` is clean. Gradle wrapper 8.14.1 and the Gradle/Loom caches went to `~/.gradle`.

## 2. Waiting for you (needs your hands)

### H1. Get a permanent JDK 21 (the scratchpad copy is temporary)
```
sudo dnf install java-21-openjdk-devel      # or unpack Temurin 21 somewhere permanent
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk   # per shell; or set org.gradle.java.home in ~/.gradle/gradle.properties
```
Do not change `gradle.properties` in the repo for this.

### H2. Unblock MCVR (sudo), then build `libcore.so`
Follow `../MCVR/HUMAN_BLOCKERS.md` B1, then B3. Skip B2, it is done. Suggested first-pass configure:
```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DJAVA_PROJECT_ROOT_DIR=$HOME/Projects/Repos/Minecraft-Radiance/Radiance \
  -DMCVR_ENABLE_FFX_UPSCALER=OFF -DMCVR_ENABLE_XESS=OFF
```
Run `cmake --install` only after reading what it writes (it puts libs and shaders into `Radiance/src/main/resources/`).

### H3. Put the native lib and shaders into the jar, then run
`RadianceClient` copies `libcore.so`, `shaders/` and `modules/` out of jar resources at startup (`RadianceClient.java:65-83`) and calls `System.load`. `libcore.so`, `libxess*` and `shaders/` are git-ignored, so an MCVR install into `src/main/resources` is the intended flow. After that: `./gradlew runClient`, which is preconfigured for 1920x1080.

### H4. Before the first launch (from the README)
- DLSS: without `libnvidia-ngx-dlss.so.310.5.3` and `libnvidia-ngx-dlssd.so.310.5.3` in `<run dir>/radiance/`, the mod crashes at startup (README says AMD users can use empty dummy files). Download them from NVIDIA/DLSS v310.5.3, `lib/Linux_x86_64/rel`. I did not download them because of the NVIDIA licence terms, so this is your decision.
- The machine has an NVIDIA RTX 4060 Laptop plus an AMD Radeon 680M. Choose which GPU MCVR should use and note it.

## 3. Decisions I made for you
- Used a scratchpad Temurin 21 rather than `dnf install` (needs sudo, not reversible by me). To undo: nothing, it is temporary.
- Did not edit `build.gradle` or `gradle.properties`, even where they look off (section 4).
- Did not write into the MCVR repo. Its `HUMAN_BLOCKERS.md` still lists B2 as open, so ignore that item.

## 4. Found but did not touch
- `gradle.properties` has `loom_version=1.14-SNAPSHOT`, but `build.gradle` hardcodes plugin `fabric-loom 1.11-SNAPSHOT` (Loom 1.11.8 ran). The property is unused, so it is misleading.
- `build.gradle` jar task copies `LICENSE`, but the file is named `LICENCE`. The jar contains no project licence (verified: only `XESS_LICENCE.txt`).
- `compileJava` has `outputs.upToDateWhen { false }`, so Java always recompiles. This appears deliberate (to regenerate JNI headers), but it slows every build.
- `java { toolchain }` is only set when the running JDK is older than 21. With JDK 25 and Gradle 8.14 the build script can't even load; adding foojay/toolchain config could make it robust.
- `build.gradle` uses `project.archivesBaseName` (deprecated, blocks Gradle 9).
- Only 2 code TODOs: `ChunkProxy.java:261` (cancel out the sort in the section builder) and `EntityProxy.java:291` (add outline). No tests exist (`compileTestJava NO-SOURCE`).
- Version bump in the upstream README says "Frame Generation" and "HDR" are not done, and porting to more versions is priority one.

## 5. Blocked
- Any runtime verification (needs MCVR native build → H2/H3, and DLSS files → H4). So I made no Java behavior changes: nothing to verify them against.

## Suggested tomorrow (in order)
1. H1 (2 min) → H2 (sudo + first build) → H3 → H4 → `runClient`.
2. Tell me the goal: bug, feature (porting, frame gen, HDR), or cleanup of section 4. The cleanup items are safe to do as a small PR once you confirm.
