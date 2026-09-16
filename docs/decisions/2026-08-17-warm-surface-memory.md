# Warm Terminal Surface Memory: Investigation and Decision

Date: 2026-08-17

Status: accepted (no code change)

## Summary

Warren Desktop retains one active terminal surface plus up to eight warm
surfaces, with a 1 GiB estimated warm-memory ceiling. This document records an
investigation into whether that formula and those limits are reasonable, what
the measured memory actually is, and how Ghostty-based alternatives handle the
same problem.

Conclusion: the formula tracks the dominant cost (Metal IOSurface buffers)
well, but it is not a real memory ceiling. Keeping eight warm surfaces fully
realized costs roughly 700-900 MB on a Retina MacBook screen. cmux solves this
with a fork-only renderer realization API that upstream libghostty does not
expose. We are not changing the policy for now; the numbers are recorded here
for future tuning.

## Current policy

Implemented in `Packages/GhosttyAdapter/Sources/GhosttyAdapter/TerminalSurfaceManager.swift`:

- `TerminalSurfaceRetentionPolicy.defaultWarmLimit = 8` (raised to 32 on
  2026-09-15 — see the update at the end)
- `TerminalSurfaceRetentionPolicy.defaultWarmByteLimit = 1024 * 1024 * 1024` (1 GiB,
  raised to 3 GiB on 2026-09-15 — see the update at the end)
- The active surface is never evicted.
- Warm surfaces are evicted LRU (oldest first) when the warm count exceeds
  `warmLimit` or the estimated warm bytes exceed `warmByteLimit`.
- Evicted surfaces are disposed to `cold`; the terminal session itself keeps
  running in ghostline and is replayed/rebuilt on reattachment.

The byte estimate is:

```text
physical pixels = viewport points width * backing scale
                * viewport points height * backing scale
estimated bytes = physical pixels * 4 bytes (BGRA) * 3 buffers
```

The 1 GiB budget only counts warm surfaces, not the active surface.

## Measurement methodology

Temporary XCTest cases in `GhosttyAdapterTests` created real surfaces through
`TerminalSurfaceManager`, switched through nine surfaces (1 active + 8 warm),
and measured process physical footprint deltas with
`task_vm_info.phys_footprint`. A second run held the same nine surfaces and was
inspected with `vmmap`. The temporary tests were removed afterward and the
repository was left clean.

Machine: 14" MacBook Pro, Apple M3, 3024x1964 Retina built-in display.

## Measured results

### Incremental footprint

| Viewport (points) | Estimate/surface | First surface (one-time) | Additional surface | 8 warm + 1 active |
|---|---:|---:|---:|---:|
| 800x600 (1600x1200 physical) | 23.0 MB | ~84 MB | ~30-36 MB | ~338 MB |
| 1512x982 (3024x1964 physical) | 71.3 MB | ~145 MB | ~75-98 MB | ~835 MB |

The first surface includes one-time Metal renderer, font, and shader
initialization shared by all surfaces. The additional-surface cost is the
relevant number for the warm pool.

### vmmap breakdown (1512x982, 9 surfaces)

| Region | Total | Notes |
|---|---:|---|
| IOSurface | ~612 MB | ~68 MB/surface; Metal drawable/swapchain buffers |
| IOAccelerator (graphics) | ~42 MB | GPU queues and related allocations |
| MALLOC (default zone) | ~48 MB allocated | Swift objects, terminal state, output writer |
| Other / one-time | ~80-145 MB | renderer, font, shader, framework setup |

`phys_footprint` for the same run was ~777 MB (peak ~827 MB); the other
measurement run reached ~835 MB. Variance comes from allocator and swap
behavior.

### Estimated warm capacity on common displays

Using the current formula only:

| Display (physical) | One surface | 8 warm total | Max warm under 1 GiB |
|---|---:|---:|---:|
| 13" MacBook (2560x1600) | 46.9 MiB | 375.0 MiB | 21 |
| 14" MacBook (3024x1964) | 68.0 MiB | 543.7 MiB | 15 |
| 16" MacBook (3456x2234) | 88.4 MiB | 706.9 MiB | 11 |
| 24" iMac (4480x2520) | 129.2 MiB | 1033.6 MiB | 7 |
| 5K Studio Display (5120x2880) | 168.8 MiB | 1350.0 MiB | 6 |
| 6K Pro Display XDR (6016x3384) | 233.0 MiB | 1863.8 MiB | 4 |

On large displays the 1 GiB budget binds before the count of eight; on the
current machine the count of eight binds first. Actual capacity is lower than
these estimates because the formula omits non-IOSurface per-surface costs.

## Why the formula is not a real memory ceiling

- It estimates the triple-buffered BGRA framebuffer, which is close to the
  measured IOSurface cost, but it omits terminal grid/scrollback, Swift state,
  GPU allocations, and renderer initialization.
- Measured per-surface cost at 1512x982 is ~86 MB versus the estimated 71 MB.
- The estimate scales with viewport size, so the effective warm count depends
  heavily on screen resolution.

## Comparison: cmux renderer realization

cmux (the Swift + libghostty Ghostty fork in `../cmux`) releases the GPU
renderer of offscreen idle terminals:

- `RendererRealizationController` is enabled by default.
- Defaults: `idleSeconds = 5`, `maxWarmRenderers = 1`.
- It calls the fork-only `ghostty_surface_set_renderer_realized` API, which
  frees the Metal swap chain / IOSurface while retaining the PTY, terminal
  state, and scrollback.
- The renderer is rebuilt on re-show, so switching to a reclaimed tab is
  slower than a warm tab but the terminal content is preserved.

Upstream Ghostty's public C API does not expose this. The current
`include/ghostty.h` only has `ghostty_surface_set_occlusion`, focus, size,
content scale, and color scheme. `set_occlusion(false)` stops rendering but
does not free the IOSurface. Warren already calls this when a surface goes
warm, which is why warm surfaces keep their memory.

## Architectural note: ghostline owns terminal state

Warren Desktop's surface is a renderer only. PTYs, raw output spools,
scrollback, and server-side libghostty-vt snapshots are owned by ghostline /
Warren Headless. A cold surface can therefore be rebuilt from spool replay or
a server snapshot without killing the session.

This means the warm pool is a pure client-side latency-versus-memory choice:

- Keeping a warm surface realized makes tab switching fast but keeps the full
  renderer memory alive.
- Releasing only the renderer (cmux approach) would require a libghostty API
  that is not available upstream.
- Dropping the surface entirely (current cold path) gives the largest memory
  savings but pays replay/snapshot rebuild cost on reattachment.

## Decision

No code changes for now. Keep:

- 1 active surface
- up to 8 warm surfaces
- 1 GiB estimated warm-memory ceiling
- current LRU eviction

The current behavior is acceptable for the primary machine. The measurements
above are recorded so the defaults can be tuned with real data if memory
becomes a problem.

## Future options if revisited

1. Switch the vendored libghostty to a fork/prebuilt that exposes
   `ghostty_surface_set_renderer_realized`, and add a
   "renderer-unrealized" residency between warm and cold.
2. Make warm count and byte budget configurable.
3. Reduce the default warm count (e.g. to 1-2) or adapt it to system memory
   pressure.
4. Rely more aggressively on ghostline's cold rebuild path.

## Update 2026-09-15: warm count raised to 32, byte ceiling raised to 3 GiB

Observed cost of the old limits: a user cycling through roughly ten open
Sessions saw a full snapshot install (and a TUI-wide repaint) on the revisit,
because the ninth surface evicted the oldest warm one. `defaultWarmLimit` is now
32, and `defaultWarmByteLimit` is 3 GiB.

Both were needed. The count alone cannot bind, because every warm surface keeps
its IOSurface (~86 MB measured at 1512x982) and the estimate scales with
viewport size, so the old 1 GiB ceiling capped the pool near 15-20 surfaces:

| Pane viewport (points, 2x) | Estimate/surface | Warm surfaces under 3 GiB |
|---|---:|---:|
| 1148x869 | ~48 MB | ~64 |
| 800x600 | ~23 MB | ~130 |
| 1512x982 | ~71 MB | ~43 |

At 3 GiB the count of 32 is the binding constraint on ordinary displays. The
trade-off is explicit: on the order of 2-3 GB of warm memory in the worst case,
against re-installing a full snapshot on every revisit. A surface whose
projection leaves the running set is still pruned immediately, so the pool only
grows with Sessions the user actually keeps open.

The durable fix for this whole class remains what the comparison section
describes: a renderer-realization API that frees the IOSurface of an idle warm
surface while keeping its terminal state. Until libghostty exposes one, the
budget is the only lever, and eviction always costs a cold attach plus a full
snapshot install.
