// Render-layer font bounds that are wider than the shared config's stored range.
/// Every font size the render layer may be asked for. `DanTermConfig.fontSizeRange`
/// and `paneFontSizeStepRange` are chosen so their sum cannot leave this range.
let renderableFontSizeRange: ClosedRange<Double> = 4...96
