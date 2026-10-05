/* Generates the three Enterprise Health Dashboard Word documents from
   docs/inventory.json (extracted from the deployment scripts and reconciled
   against the live database).

   node deploy/New-EhdDocs.js
*/
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, BorderStyle, ShadingType,
  PageBreak, Header, Footer, PageNumber, TableOfContents, convertInchesToTwip
} = require('docx');

const ROOT = path.resolve(__dirname, '..');

/* Output lives OUTSIDE the OneDrive-synced tree on purpose.
   The tenant auto-labelling policy re-writes .docx files created inside
   "OneDrive - Microsoft" as MIP-encrypted OLE compound files (magic D0CF11E0)
   within seconds, which makes them unreadable by every docx tool and breaks
   structural validation. Generate here, then copy in deliberately if the
   document should carry a sensitivity label. */
const DOCS = process.env.EHD_DOCS_OUT || path.join(require('os').homedir(), 'EHD-Docs');
if (!fs.existsSync(DOCS)) fs.mkdirSync(DOCS, { recursive: true });

const INVENTORY = path.join(ROOT, 'docs', 'inventory.json');
const inv = JSON.parse(fs.readFileSync(INVENTORY, 'utf8'));

const ACCENT = '1F3864';
const LIGHT = 'DCE6F1';
const CODEBG = 'F2F2F2';

/* ---------------------------------------------------------------- helpers */
const H1 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_1, spacing: { before: 360, after: 160 } });
const H2 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_2, spacing: { before: 280, after: 120 } });
const H3 = t => new Paragraph({ text: t, heading: HeadingLevel.HEADING_3, spacing: { before: 220, after: 100 } });

const P = (t, opts = {}) => new Paragraph({
  spacing: { after: opts.after === undefined ? 120 : opts.after },
  children: [new TextRun({ text: t, bold: !!opts.bold, italics: !!opts.italics,
                           color: opts.color, size: opts.size })]
});

const RICH = runs => new Paragraph({ spacing: { after: 120 }, children: runs });
const RUN = (t, o = {}) => new TextRun({ text: t, bold: !!o.bold, italics: !!o.italics,
                                         font: o.mono ? 'Consolas' : undefined,
                                         color: o.color, size: o.size });

const BULLET = (t, lvl = 0) => new Paragraph({
  text: t, bullet: { level: lvl }, spacing: { after: 60 }
});

const NUM = (t, ref) => new Paragraph({
  text: t, numbering: { reference: ref, level: 0 }, spacing: { after: 60 }
});

function CODE(lines) {
  const arr = Array.isArray(lines) ? lines : String(lines).split('\n');
  return arr.map((ln, i) => new Paragraph({
    spacing: { before: i === 0 ? 100 : 0, after: i === arr.length - 1 ? 140 : 0 },
    shading: { type: ShadingType.CLEAR, fill: CODEBG },
    indent: { left: convertInchesToTwip(0.15) },
    children: [new TextRun({ text: ln || ' ', font: 'Consolas', size: 17 })]
  }));
}

function CALLOUT(title, body, fill) {
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    borders: ['top', 'bottom', 'left', 'right', 'insideHorizontal', 'insideVertical']
      .reduce((a, k) => (a[k] = { style: BorderStyle.SINGLE, size: 2, color: fill || 'C00000' }, a), {}),
    rows: [new TableRow({
      children: [new TableCell({
        shading: { type: ShadingType.CLEAR, fill: 'FDF2F2' },
        margins: { top: 120, bottom: 120, left: 160, right: 160 },
        children: [
          new Paragraph({ spacing: { after: 60 }, children: [RUN(title, { bold: true, color: fill || 'C00000' })] })
        ].concat(
          (Array.isArray(body) ? body : [body]).map(b =>
            new Paragraph({ spacing: { after: 40 }, children: [RUN(b)] }))
        )
      })]
    })]
  });
}

function TBL(headers, rows, widths) {
  const w = widths || headers.map(() => Math.floor(100 / headers.length));
  const hdr = new TableRow({
    tableHeader: true,
    children: headers.map((h, i) => new TableCell({
      width: { size: w[i], type: WidthType.PERCENTAGE },
      shading: { type: ShadingType.CLEAR, fill: ACCENT },
      margins: { top: 60, bottom: 60, left: 100, right: 100 },
      children: [new Paragraph({ children: [RUN(h, { bold: true, color: 'FFFFFF', size: 18 })] })]
    }))
  });
  const body = rows.map((r, ri) => new TableRow({
    children: r.map((c, i) => new TableCell({
      width: { size: w[i], type: WidthType.PERCENTAGE },
      shading: ri % 2 ? { type: ShadingType.CLEAR, fill: 'F7F9FC' } : undefined,
      margins: { top: 50, bottom: 50, left: 100, right: 100 },
      children: String(c).split('\n').map(line => new Paragraph({
        children: [RUN(line, { mono: /^[\[\w]*\.|^@|^N'|^EXEC|^SELECT|^\w+\(/.test(line) && i === 0, size: 17 })]
      }))
    }))
  }));
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    rows: [hdr].concat(body)
  });
}

const SPACER = () => new Paragraph({ text: '', spacing: { after: 160 } });
const BREAK = () => new Paragraph({ children: [new PageBreak()] });

function docShell(title, subtitle, children) {
  return new Document({
    creator: 'Enterprise Health Dashboard',
    title: title,
    description: subtitle,
    numbering: {
      config: [{
        reference: 'steps',
        levels: [{ level: 0, format: 'decimal', text: '%1.', alignment: AlignmentType.START,
                   style: { paragraph: { indent: { left: 420, hanging: 260 } } } }]
      }]
    },
    styles: {
      default: {
        document: { run: { font: 'Segoe UI', size: 20 } },
        heading1: { run: { font: 'Segoe UI Semibold', size: 32, color: ACCENT }, paragraph: { spacing: { before: 360, after: 160 } } },
        heading2: { run: { font: 'Segoe UI Semibold', size: 26, color: ACCENT }, paragraph: { spacing: { before: 280, after: 120 } } },
        heading3: { run: { font: 'Segoe UI Semibold', size: 22, color: '2E5496' }, paragraph: { spacing: { before: 220, after: 100 } } }
      }
    },
    sections: [{
      properties: { page: { margin: { top: 1000, bottom: 1000, left: 1000, right: 1000 } } },
      headers: {
        default: new Header({ children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [RUN(title, { size: 16, color: '808080' })]
        })] })
      },
      footers: {
        default: new Footer({ children: [new Paragraph({
          alignment: AlignmentType.CENTER,
          children: [RUN('Page ', { size: 16, color: '808080' }),
                     new TextRun({ children: [PageNumber.CURRENT], size: 16, color: '808080' }),
                     RUN(' of ', { size: 16, color: '808080' }),
                     new TextRun({ children: [PageNumber.TOTAL_PAGES], size: 16, color: '808080' })]
        })] })
      },
      children: [
        new Paragraph({ spacing: { before: 2200, after: 120 }, alignment: AlignmentType.CENTER,
          children: [RUN(title, { bold: true, size: 56, color: ACCENT })] }),
        new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
          children: [RUN(subtitle, { size: 24, color: '595959' })] }),
        new Paragraph({ alignment: AlignmentType.CENTER,
          children: [RUN('Azure SQL Database  |  Elastic Jobs  |  Managed identity', { size: 18, color: '808080' })] }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 },
          children: [RUN('Generated ' + new Date().toISOString().slice(0, 10) +
                         '  -  verified against the live deployment', { size: 18, color: '808080' })] }),
        BREAK()
      ].concat(children)
    }]
  });
}

async function save(doc, file) {
  const buf = await Packer.toBuffer(doc);
  fs.writeFileSync(path.join(DOCS, file), buf);
  console.log('wrote docs\\' + file + '  (' + (buf.length / 1024).toFixed(0) + ' KB)');
}

module.exports = { H1, H2, H3, P, RICH, RUN, BULLET, NUM, CODE, CALLOUT, TBL,
                   SPACER, BREAK, docShell, save, inv, DOCS };
