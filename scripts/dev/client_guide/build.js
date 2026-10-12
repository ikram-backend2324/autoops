// Builds the client guide (Word) from a language content file.
//   node scripts/dev/client_guide/build.js            -> instructions.docx, instructions_ru.docx, instructions_uz.docx
//   node scripts/dev/client_guide/build.js ru         -> one language
// Requires the "docx" npm package (npm install docx). The layout lives here; all text lives in
// content.<lang>.js, so the three versions always have the same structure.
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, ImageRun, LevelFormat, Footer, Header, PageNumber,
} = require("docx");

const ROOT = path.resolve(__dirname, "../../..");
const SHOTS = path.join(ROOT, "docs/screenshots");
const OUTPUT = { en: "instructions.docx", ru: "instructions_ru.docx", uz: "instructions_uz.docx" };

const C = { primary: "1F4E79", accent: "2E75B6", light: "EAF1FB", grey: "F2F2F2", text: "222222", muted: "666666", warn: "FFF2CC" };
const CONTENT_W = 9026; // A4 width 11906 - 2 x 1440 margins
const FONT = "Calibri";

// "**bold** plain" -> TextRuns
function runs(text, base = {}) {
  return String(text).split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((part) => (part.startsWith("**")
    ? new TextRun({ ...base, text: part.slice(2, -2), bold: true })
    : new TextRun({ ...base, text: part })));
}
const para = (text, extra = {}, base = {}) => new Paragraph({ spacing: { after: 120, line: 276 }, ...extra, children: runs(text, base) });
const note = (text) => para(text, {}, { italics: true, color: C.muted });

const border = { style: BorderStyle.SINGLE, size: 4, color: "BFBFBF" };
const borders = { top: border, bottom: border, left: border, right: border };

function table({ headers, rows, widths, boldFirst }) {
  const total = widths.reduce((a, c) => a + c, 0);
  const cell = (text, w, header, fill, bold) => new TableCell({
    borders,
    width: { size: w, type: WidthType.DXA },
    shading: { fill: header ? C.primary : fill, type: ShadingType.CLEAR, color: "auto" },
    margins: { top: 80, bottom: 80, left: 110, right: 110 },
    children: [new Paragraph({ spacing: { after: 0 },
      children: runs(text, { bold: header || bold, color: header ? "FFFFFF" : C.text, size: 20 }) })],
  });
  return new Table({
    width: { size: total, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: headers.map((h, k) => cell(h, widths[k], true)) }),
      ...rows.map((r, n) => new TableRow({ cantSplit: true,
        children: r.map((c, k) => cell(c, widths[k], false, n % 2 ? C.grey : "FFFFFF", boldFirst && k === 0)) })),
    ],
  });
}

function callout({ title, lines, tone }) {
  const fill = tone === "warn" ? C.warn : C.light;
  const edge = { style: BorderStyle.SINGLE, size: 4, color: fill };
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: [CONTENT_W],
    rows: [new TableRow({ cantSplit: true, children: [new TableCell({
      width: { size: CONTENT_W, type: WidthType.DXA },
      shading: { fill, type: ShadingType.CLEAR, color: "auto" },
      borders: { top: edge, bottom: edge, right: edge, left: { style: BorderStyle.SINGLE, size: 24, color: C.accent } },
      margins: { top: 120, bottom: 120, left: 200, right: 200 },
      children: [
        new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: title, bold: true, color: C.primary })] }),
        ...lines.map((l) => new Paragraph({ spacing: { after: 40 }, children: runs(l, { size: 21 }) })),
      ],
    })] })],
  });
}

function image({ file, w, h, max = 600, caption }) {
  const scale = Math.min(1, max / w);
  return [
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 120, after: 60 }, keepNext: true,
      children: [new ImageRun({ type: "png", data: fs.readFileSync(path.join(SHOTS, file)),
        transformation: { width: Math.round(w * scale), height: Math.round(h * scale) },
        altText: { title: caption, description: caption, name: file } })] }),
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 }, children: [new TextRun({ text: caption, italics: true, color: C.muted })] }),
  ];
}

let listInstance = 0;
function block(b) {
  switch (b.type) {
    case "p": return [para(b.text)];
    case "note": return [note(b.text)];
    case "h2": return [new Paragraph({ heading: HeadingLevel.HEADING_2, pageBreakBefore: !!b.newPage, keepNext: true, children: [new TextRun(b.text)] })];
    case "bullets": return b.items.map((t) => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 60 }, children: runs(t) }));
    case "steps": {
      listInstance += 1;
      return b.items.map((t) => new Paragraph({ numbering: { reference: "steps", level: 0, instance: listInstance }, spacing: { after: 80 }, children: runs(t) }));
    }
    case "table": return [table(b), new Paragraph({ spacing: { after: 120 }, children: [] })];
    case "callout": return [callout(b), new Paragraph({ spacing: { after: 120 }, children: [] })];
    case "image": return image(b);
    case "faq": return b.items.flatMap(([q, a]) => [
      new Paragraph({ spacing: { before: 160, after: 40 }, keepNext: true, children: [new TextRun({ text: q, bold: true, color: C.primary })] }),
      para(a),
    ]);
    default: throw new Error(`unknown block type ${b.type}`);
  }
}

function build(lang) {
  const t = require(`./content.${lang}.js`);
  listInstance = 0;
  const cover = [
    new Paragraph({ spacing: { before: 2400, after: 200 }, children: [new TextRun({ text: "AutoOps", bold: true, size: 72, color: C.primary })] }),
    new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: t.cover.subtitle, size: 36, color: C.accent })] }),
    new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: C.accent, space: 8 } }, spacing: { after: 400 }, children: [] }),
    new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: t.cover.title, size: 26 })] }),
    new Paragraph({ spacing: { after: 1600 }, children: [new TextRun({ text: t.cover.audience, size: 24, color: C.muted })] }),
    table({ headers: t.cover.tableHeaders, rows: t.cover.rows, widths: [3000, 6026] }),
  ];
  const contents = [
    new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [new TextRun(t.contentsTitle)] }),
    ...t.sections.map((s) => new Paragraph({ spacing: { after: 140 }, children: [
      new TextRun({ text: s.title, bold: true, color: C.primary, size: 24 }),
      new TextRun({ text: `  —  ${s.summary}`, color: C.muted }),
    ] })),
  ];
  const body = t.sections.flatMap((s) => [
    new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [new TextRun(s.title)] }),
    ...s.blocks.flatMap(block),
  ]);

  const doc = new Document({
    creator: "AutoOps",
    title: t.meta.title,
    description: t.meta.description,
    styles: {
      default: { document: { run: { font: FONT, size: 22, color: C.text } } },
      paragraphStyles: [
        { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: 34, bold: true, font: FONT, color: C.primary }, paragraph: { spacing: { before: 120, after: 200 }, outlineLevel: 0 } },
        { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: 26, bold: true, font: FONT, color: C.accent }, paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 1 } },
      ],
    },
    numbering: { config: [
      { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
      { reference: "steps", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
    ] },
    sections: [{
      properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
      headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
        children: [new TextRun({ text: t.meta.header, size: 18, color: C.muted })] })] }) },
      footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
        children: [new TextRun({ children: [t.meta.page, " ", PageNumber.CURRENT, ` ${t.meta.of} `, PageNumber.TOTAL_PAGES], size: 18, color: C.muted })] })] }) },
      children: [...cover, ...contents, ...body],
    }],
  });
  const out = path.join(ROOT, OUTPUT[lang]);
  return Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(out, buf); console.log(`wrote ${out}`); });
}

const langs = process.argv[2] ? [process.argv[2]] : Object.keys(OUTPUT);
Promise.all(langs.map(build)).catch((e) => { console.error(e); process.exit(1); });
