// Shared markup helpers and theme for the TypeAgent document set.

#import "@local/folia-lucida:0.1.0": theme, default-theme

// This set is written in Traditional Chinese, but the package's default
// `zh-Hant` preset references a couple of families that are not installed
// locally ("I.Ming", "LXGW WenKai TC"). The override below keeps the intended
// look while using the fonts that are actually available, so builds stay
// warning-free.
#let _latin-serif = (name: "IBM Plex Serif", covers: "latin-in-cjk")

#let doc-theme = theme.with(
  fonts: (
    ..default-theme.fonts,
    "zh-Hant": (
      ..default-theme.fonts.at("zh-Hant"),
      display-serif: (_latin-serif, "一點明體", "LXGW Neo ZhiSong", "Noto Serif TC"),
      text-serif: (_latin-serif, "Noto Serif TC"),
      script-serif: (_latin-serif, "LXGW WenKai", "Noto Serif TC"),
    ),
  ),
)

// `doc-table` renders a Markdown-like table with a shaded header row so the
// converted documents keep the visual hierarchy of the original `| ... |`
// tables without repeating layout code in every file.
#let doc-table(columns, header, size: 9.5pt, inset: (x: 5pt, y: 4pt), ..cells) = {
  set text(size: size)
  set par(first-line-indent: 0em, justify: false, leading: 0.68em)
  table(
    columns: columns,
    inset: inset,
    align: (left, top),
    stroke: 0.4pt + luma(210),
    fill: (col, row) => if row == 0 { luma(245) },
    table.header(..header),
    ..cells,
  )
}

// A compact metadata block for the front of each converted document.
#let doc-meta(body) = block(
  width: 100%,
  inset: (x: 8pt, y: 6pt),
  radius: 3pt,
  fill: luma(247),
  stroke: 0.4pt + luma(215),
  [
    #set par(first-line-indent: 0em, justify: false)
    #set text(size: 9pt)
    #body
  ],
)

// Lists and tables should not inherit the body's first-line indent or
// justification; cells read better left-aligned and slightly smaller.
#let doc-setup(body) = {
  show list: set par(first-line-indent: 0em, justify: false)
  show enum: set par(first-line-indent: 0em, justify: false)
  show table: set par(first-line-indent: 0em, justify: false, leading: 0.66em)
  show table: set text(size: 9.5pt)
  show table: it => {
    show raw: set text(size: 8pt)
    it
  }
  body
}
