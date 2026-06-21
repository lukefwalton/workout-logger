# 004 — Swipe Navigation

Adopting the thing I liked in app-mobile: swipe horizontally to move between the
home screens (Today / History / Progress / Settings), with a tab bar that swipe
and tap both drive.

## The real decision: native paging vs. hand-rolled gesture

app-mobile's pager is a finger-tracked `Animated` strip on `PanResponder`, and
the genuinely clever part is `swipeGesture.ts`: `shouldClaimHorizontalSwipe`
only claims a drag once it's *dominantly horizontal*, so the vertical scrolling
inside each screen is left alone. That arbitration is the whole ballgame —
every one of our screens is a vertical `Form`/`List`, so a naive horizontal
`DragGesture` on a container would fight them.

I went with the **native iOS 17 paging scroll** instead of porting the gesture
pager:

```
ScrollView(.horizontal) { HStack { pages.containerRelativeFrame([.horizontal,.vertical]) }.scrollTargetLayout() }
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $tab)
```

The system arbitrates horizontal-page vs. vertical-scroll for us, correctly —
the exact thing app-mobile had to hand-build. `scrollPosition` two-way-binds to
the selected tab, so a swipe updates the bar and a tap (`withAnimation(.snappy)`)
animates the scroll. The custom bottom bar rides on `safeAreaInset(edge:.bottom)`
so it insets content and extends under the home indicator like a real tab bar.

## Why not match app-mobile's exact feel (yet)

The thing I *didn't* do is port app-mobile's tuned knobs — `PAGE_SNAP_SPEED`,
`EDGE_RESISTANCE`, the `distanceFraction: 0.26` / `velocity: 0.3` commit
thresholds. The native paging API doesn't expose them; its feel is the system's
(very good, and what App Store-style carousels use, but not byte-identical to
app-mobile's spring). Matching app-mobile exactly means the hand-rolled
`DragGesture` pager — and that's precisely the work I *shouldn't* do blind:
gesture claiming and spring constants are pure feel, and there's no simulator
here to iterate against. If we want that, it's a focused follow-up where the
ported `swipeGesture` thresholds (lifted straight from app-mobile) become a pure,
testable `SwipeFeel` type and you tune the spring on a device.

## Small things carried over from app-mobile

- **Peer pages stay peers; drill-downs stay pushes.** Each screen is its own
  `NavigationStack`. app-mobile kept the PDF viewer a separately-pushed route so
  it'd keep its native back-swipe; the equivalent for us is that chart detail
  (Track 4) and any future drill-down should be a push *inside* a page, not a
  fifth peer in the swipe strip — otherwise it'd fight the pager.
- **The order is the contract.** `AppTab.allCases` order is the left-to-right
  page order and the bar order at once; `AppTabTests` pins it so a refactor can't
  silently desync them.

## Honest caveat

`RootTabView` is unverified — written correctly-by-inspection, but the swipe
feel, the bar's safe-area fit, and the nested-scroll arbitration all want a real
Xcode/device pass. The only thing I could actually test here is the tab ordering.

## Next

If the native feel isn't close enough to app-mobile on device, the follow-up is
the custom `SwipeFeel` pager described above. Otherwise, back to the feature
tracks: History/audit view, then Swift Charts (Track 4).
