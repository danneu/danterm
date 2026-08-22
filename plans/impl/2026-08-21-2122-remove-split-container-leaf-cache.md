# Remove the Split Container Leaf Cache

## Problem

`SplitContainerView` caches pane leaves even though its direct child wrappers
already describe the mounted-pane set. The cache can hold a generic view when
wrapper lookup returns nil. That entry permanently suppresses later lookup for
the pane, so a real wrapper that becomes available later cannot replace the
blank view.

Current production construction installs pane hosts before container
reconciliation, and creation failure removes the containing tab. No reachable
production failure is known. The duplicate state can still drift from the
runtime and turn a later ordering change into a silent permanent blank pane.

## Decision

Delete the leaf cache. Derive mounted-pane identity from the container's direct
`PaneWrapperView` children, remove wrappers whose pane ids left the model, and
resolve every desired pane through the runtime-owned wrapper lookup on each
layout pass. A missing wrapper produces no subview. Existing model-layout
passes will retry unchanged pane ids, so a wrapper that becomes available later
mounts through the normal layout path.

Keep wrapper lookup optional and keep its weak owner capture. Do not make
missing-wrapper recovery depend on a stronger AppKit lifetime assumption.

## Invariants

- The direct child wrappers are the container's only mounted-pane state.
- A failed wrapper lookup cannot suppress a later lookup for the same pane id.
- The container never presents a substitute view as pane content.
- Wrapper identity, model-derived geometry, zoom visibility, and divider
  behavior remain unchanged when every wrapper is available.

## Proof obligations

- A layout pass with no wrapper mounts no pane content; after the same lookup
  begins returning a wrapper, a later layout mounts that exact wrapper at the
  model-derived frame.
- Existing split-container tests continue to prove that tree updates preserve
  wrappers and assign only true model geometry, including for hidden tabs.
- A wrapper whose pane id leaves a container's model tree is no longer its
  child, while a wrapper already adopted by another container remains mounted
  in that destination.
- Existing creation-failure and restore tests continue to prove the premise
  that production reconciliation does not retain a live model pane without its
  runtime host.
- Run `just test-ui` before commit. The normal `just test` gate excludes the
  WindowServer-dependent container suite and does not prove this recovery path.

## Non-goals and accepted risk

- Do not change session creation, restore, failure, or reconciliation ordering.
- Do not change divider storage or reconciliation.
- Do not add a timer, command, message, placeholder type, or other active retry
  driver.
- Accepted risk: a missing wrapper stays absent until an existing layout trigger
  runs. Current production ordering prevents that interval from being visible;
  the recovery path exists to keep a transient miss from becoming permanent.
