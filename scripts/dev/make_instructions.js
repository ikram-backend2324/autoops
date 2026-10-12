// Generates the client-facing AutoOps guide (instructions.docx). No code topics - features,
// how to verify them, and going to production.
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, ImageRun, LevelFormat, Footer, Header, PageNumber,
} = require("docx");

const ROOT = path.resolve(__dirname, "../..");
const SHOTS = path.join(ROOT, "docs/screenshots");
const OUT = process.argv[2] || path.join(ROOT, "instructions.docx");  // needs: npm install docx

const C = { primary: "1F4E79", accent: "2E75B6", light: "EAF1FB", grey: "F2F2F2", text: "222222", muted: "666666", ok: "E2F0D9", warn: "FFF2CC", bad: "FBE4E4" };
const CONTENT_W = 9026; // A4 width 11906 - 2 x 1440 margins
const FONT = "Calibri";

// ---------------------------------------------------------------- helpers
const p = (text, opts = {}) => new Paragraph({
  spacing: { after: 120, line: 276 },
  ...opts.para,
  children: (Array.isArray(text) ? text : [text]).map((t) => (typeof t === "string" ? new TextRun({ text: t, ...opts.run }) : t)),
});
const b = (text) => new TextRun({ text, bold: true });
const i = (text) => new TextRun({ text, italics: true, color: C.muted });
const h1 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [new TextRun(text)] });
const h2 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(text)] });
const bullet = (parts, level = 0) => new Paragraph({
  numbering: { reference: "bullets", level },
  spacing: { after: 60 },
  children: (Array.isArray(parts) ? parts : [parts]).map((t) => (typeof t === "string" ? new TextRun(t) : t)),
});
const numbered = (parts, instance) => new Paragraph({
  numbering: { reference: "steps", level: 0, instance },
  spacing: { after: 80 },
  children: (Array.isArray(parts) ? parts : [parts]).map((t) => (typeof t === "string" ? new TextRun(t) : t)),
});

const border = { style: BorderStyle.SINGLE, size: 4, color: "BFBFBF" };
const borders = { top: border, bottom: border, left: border, right: border };

function table(headers, rows, widths, opts = {}) {
  const total = widths.reduce((a, c) => a + c, 0);
  const cell = (content, w, header, fill) => new TableCell({
    borders,
    width: { size: w, type: WidthType.DXA },
    shading: { fill: header ? C.primary : (fill || "FFFFFF"), type: ShadingType.CLEAR, color: "auto" },
    margins: { top: 80, bottom: 80, left: 110, right: 110 },
    children: (Array.isArray(content) ? content : [content]).map((c) => (c instanceof Paragraph ? c : new Paragraph({
      spacing: { after: 0 },
      children: [typeof c === "string" ? new TextRun({ text: c, bold: header, color: header ? "FFFFFF" : C.text, size: 20 }) : c],
    }))),
  });
  return new Table({
    width: { size: total, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: headers.map((h, k) => cell(h, widths[k], true)) }),
      ...rows.map((r, n) => new TableRow({
        children: r.map((c, k) => cell(c, widths[k], false, (opts.fills && opts.fills[n]) || (n % 2 ? C.grey : "FFFFFF"))),
      })),
    ],
  });
}

function callout(title, lines, fill = C.light) {
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: [CONTENT_W],
    rows: [new TableRow({ children: [new TableCell({
      width: { size: CONTENT_W, type: WidthType.DXA },
      shading: { fill, type: ShadingType.CLEAR, color: "auto" },
      borders: { top: { style: BorderStyle.SINGLE, size: 4, color: fill }, bottom: { style: BorderStyle.SINGLE, size: 4, color: fill },
        right: { style: BorderStyle.SINGLE, size: 4, color: fill }, left: { style: BorderStyle.SINGLE, size: 24, color: C.accent } },
      margins: { top: 120, bottom: 120, left: 200, right: 200 },
      children: [
        new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: title, bold: true, color: C.primary })] }),
        ...lines.map((l) => new Paragraph({ spacing: { after: 40 }, children: (Array.isArray(l) ? l : [l]).map((t) => (typeof t === "string" ? new TextRun({ text: t, size: 21 }) : t)) })),
      ],
    })] })],
  });
}

function image(file, pxWidth, pxHeight, maxWidthPx = 600, caption) {
  const scale = Math.min(1, maxWidthPx / pxWidth);
  const out = [new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 120, after: 60 },
    children: [new ImageRun({
      type: "png",
      data: fs.readFileSync(path.join(SHOTS, file)),
      transformation: { width: Math.round(pxWidth * scale), height: Math.round(pxHeight * scale) },
      altText: { title: caption || file, description: caption || file, name: file },
    })],
  })];
  if (caption) out.push(new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 }, children: [i(caption)] }));
  return out;
}
const spacer = () => new Paragraph({ spacing: { after: 120 }, children: [] });

// ---------------------------------------------------------------- content
const cover = [
  new Paragraph({ spacing: { before: 2400, after: 200 }, children: [new TextRun({ text: "AutoOps", bold: true, size: 72, color: C.primary })] }),
  new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: "Self-healing server platform for your website", size: 36, color: C.accent })] }),
  new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: C.accent, space: 8 } }, spacing: { after: 400 }, children: [] }),
  new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: "Client guide: what you get, how to check it, and how we go live", size: 26 })] }),
  new Paragraph({ spacing: { after: 1600 }, children: [new TextRun({ text: "No technical knowledge required.", size: 24, color: C.muted })] }),
  table(["Project", "Details"], [
    ["Website address", "to be filled in at launch (e.g. https://shop.yourcompany.uz)"],
    ["Monitoring dashboard", "https://grafana.<your domain> (login provided separately)"],
    ["Alerts", "Telegram group \"Alerts — <your company>\""],
    ["Support contact", "<name, Telegram, phone>"],
    ["Document version", "1.0 — October 2026"],
  ], [3000, 6026]),
];

const SECTIONS = [
  ["1. What AutoOps is", "the idea in plain words, before and after"],
  ["2. Features and what they mean for you", "every capability and its benefit"],
  ["3. What you will see day to day", "Telegram alerts, weekly report, dashboards"],
  ["4. How to check it yourself", "acceptance checklist and our test results"],
  ["5. Backups and recovery", "what is saved, how long, how to restore"],
  ["6. Security", "how the server is protected"],
  ["7. Going to production", "what we need, launch plan, support levels"],
  ["8. Common alerts explained", "what each message means"],
  ["9. Frequently asked questions", "and contacts"],
];
const toc = [
  new Paragraph({ heading: HeadingLevel.HEADING_1, pageBreakBefore: true, children: [new TextRun("Contents")] }),
  ...SECTIONS.map(([title, desc]) => new Paragraph({
    spacing: { after: 140 },
    children: [new TextRun({ text: title, bold: true, color: C.primary, size: 24 }), new TextRun({ text: "  —  " + desc, color: C.muted })],
  })),
];

const s1 = [
  h1("1. What AutoOps is"),
  p("Most websites run on a server that nobody watches. When something breaks — the database stops, the disk fills up, the security certificate expires — the business usually finds out from its customers, sometimes hours later. Restoring service is manual, and backups often turn out to be missing or unusable exactly when they are needed."),
  p(["AutoOps turns your server into a platform that ", b("watches itself, repairs itself and tells you what happened"), ". It is the same idea large companies use (site reliability engineering), packaged for a single server and a small team."]),
  h2("In one sentence"),
  callout("AutoOps in one sentence", ["Your website runs on a secure server that notices problems within a minute, fixes the common ones automatically within seconds, sends a clear message to your Telegram, and keeps encrypted backups that are test-restored every week."]),
  h2("Before and after"),
  table(["", "Typical server today", "With AutoOps"], [
    ["Finding out about an outage", "Customers complain", "Telegram message within about 1 minute"],
    ["Recovery", "Manual, 30–120 minutes", "Automatic, usually 5–80 seconds"],
    ["Backups", "Unclear, never tested", "Every night, stored off-site, restore tested every week"],
    ["Security certificate (HTTPS)", "Can expire unnoticed", "Renewed automatically, warning 14 days ahead"],
    ["Releasing a new version", "Manual and risky", "Automatic, with instant return to the previous version if it fails"],
    ["Visibility", "None", "Live dashboards and a weekly report"],
  ], [2600, 3013, 3413]),
];

const s2 = [
  h1("2. Features and what they mean for you"),
  table(["Capability", "What it does", "Your benefit"], [
    [b("Secure server setup"), "Server hardened: only key-based access, firewall, brute-force protection, automatic security updates", "Lower risk of hacking; less manual maintenance"],
    [b("HTTPS for every site"), "Free certificates issued and renewed automatically; security headers; protection against request floods", "The browser padlock is always there; better SEO and trust"],
    [b("Live monitoring"), "Server load, memory, disk, database, website speed and errors measured every 15 seconds", "Problems are visible before customers notice"],
    [b("Alerts in Telegram"), "Clear messages in plain language: what happened, since when, what to do; \"Resolved\" when it is fixed", "You know immediately — on your phone"],
    [b("Self-healing"), "Crashed or frozen parts restart automatically; a stopped database is brought back; a full disk is cleaned", "Most incidents are over before anyone has to act"],
    [b("Protection from repair loops"), "If the same fix fails 3 times in an hour, automation stops and sends a \"human needed\" alert", "No silent endless restarts; a person is called in when needed"],
    [b("Nightly backups"), "Database and uploaded files, encrypted, stored at an external storage provider", "Data survives even if the server is lost"],
    [b("Weekly restore test"), "Every Sunday the latest backup is restored into a temporary copy and checked", "Proof — not hope — that backups work"],
    [b("Central logs"), "All application messages collected and searchable", "Faster investigation of any issue"],
    [b("Safe releases"), "New versions are tested, installed and checked automatically; a failing version is rolled back", "Updates without fear of a broken site"],
    [b("Weekly report"), "Availability %, incidents, automatic repairs, backups, disk space, pending updates", "One message a week shows the health of your system"],
    [b("Several projects, one server"), "Multiple websites can share one server, each isolated", "Lower hosting costs"],
  ], [2300, 3863, 2863]),
];

const s3 = [
  h1("3. What you will see day to day"),
  h2("3.1 Telegram alerts"),
  p("All messages arrive in a Telegram group you choose. Each message says how serious it is, which server and site, what happened, since when, and what is being done."),
  table(["Icon", "Level", "Meaning", "Notification"], [
    ["🔴", "Critical", "Site or database unavailable, backups failing", "With sound, any time of day"],
    ["🟠", "Warning", "Something needs attention soon (disk 80%, slow responses)", "With sound; quiet at night 23:00–08:00"],
    ["🔵", "Info", "For your information (a part was restarted automatically)", "Silent"],
    ["🔧", "Self-healing", "The system fixed something by itself, and how", "Shown in the group"],
    ["✅", "Resolved", "The problem is over", "Shown in the group"],
  ], [900, 1400, 4026, 2700]),
  ...image("telegram-alerts.png", 620, 528, 380, "Example: database stopped → automatic recovery → resolved (messages can be in Russian, Uzbek or English)"),
  h2("3.2 Weekly report"),
  p("Every Monday at 09:00 (Tashkent time) a short report arrives in Telegram:"),
  bullet("availability of each website for the last 7 days;"),
  bullet("number of incidents and automatic repairs;"),
  bullet("last backup and the result of the restore test;"),
  bullet("disk usage and pending security updates."),
  h2("3.3 Monitoring dashboards"),
  p("Dashboards are web pages with live charts. You open them in a browser with the login we provide. The most useful ones:"),
  bullet([b("Server overview"), " — load, memory, disk, active alerts."]),
  bullet([b("Application"), " — requests per second, errors, response time, and recent log messages."]),
  bullet([b("Availability and SSL"), " — uptime percentage and days until the certificate renews."]),
  bullet([b("Backups"), " — time since the last backup and the result of the weekly restore test."]),
  bullet([b("Containers"), ", ", b("Database"), ", ", b("Logs"), " — for deeper investigation."]),
  ...image("server-overview.png", 1600, 1402, 600, "Server overview (the spikes are a deliberate stress test)"),
  ...image("app.png", 1600, 1288, 600, "Application dashboard"),
  ...image("backups.png", 1600, 832, 600, "Backups dashboard: last backup OK, restore test OK"),
];

const s4 = [
  h1("4. How to check it yourself"),
  p("You do not have to take our word for it. The checks below can be done together during handover (about 30–45 minutes). Tick each line when it passes."),
  h2("4.1 Acceptance checklist"),
  table(["#", "Check", "How", "Expected result", "✓"], [
    ["1", "Website opens securely", "Open the site in a browser", "Page loads, padlock icon in the address bar", ""],
    ["2", "HTTP redirects to HTTPS", "Type the address with http://", "Browser ends up on https://", ""],
    ["3", "Health page", "Open <your site>/health/", "Shows status \"ok\" for database and cache", ""],
    ["4", "Dashboards", "Log in to the monitoring address", "Charts show live data", ""],
    ["5", "Test alert", "We send a test alert", "Message in Telegram, then \"Resolved\"", ""],
    ["6", "Automatic restart", "We stop the application process", "Site back within ~10 s; info message", ""],
    ["7", "Database recovery", "We stop the database", "🔴 alert, 🔧 automatic recovery, ✅ resolved within ~2 min", ""],
    ["8", "Backup", "We start a backup on request", "💾 \"Backup completed\" message", ""],
    ["9", "Restore test", "We run the restore check", "🧪 \"Restore check passed\" with row counts", ""],
    ["10", "Release and rollback", "We publish a deliberately broken version", "Old version keeps running; ❌ message about rollback", ""],
    ["11", "Security", "We try to log in with a password / as administrator", "Access refused", ""],
    ["12", "Certificate", "Check with ssllabs.com/ssltest", "Grade A", ""],
  ], [450, 2000, 2350, 3626, 600]),
  spacer(),
  callout("Tests 6, 7 and 10 deliberately break things", ["We run them in an agreed time window (or on a copy of your site) so your customers are not affected. Each one takes 1–3 minutes, and the system repairs itself."], C.warn),
  new Paragraph({ heading: HeadingLevel.HEADING_2, pageBreakBefore: true, children: [new TextRun("4.2 Results from our own test run")] }),
  p("Before handover we run five failure scenarios on purpose and measure the response. These are the results from our latest run:"),
  table(["Failure we caused", "Detected after", "Recovered after", "Notification"], [
    ["Application process killed", "4 s", "8 s", "Info: container restarted"],
    ["Application frozen (not responding)", "32 s", "44 s", "Self-healing message"],
    ["Database stopped", "5 s", "80 s", "Critical alert + self-healing + resolved"],
    ["Disk filled to 92%", "14 s", "17 s", "Self-healing: space freed"],
    ["Processor at 100% on all cores", "93 s", "after load stopped", "Warning: high CPU"],
  ], [3300, 1700, 1800, 2226]),
  p(i("High processor load is reported but not \"repaired\" automatically, because the right action depends on the cause (a traffic peak needs a bigger server, a faulty task needs a fix).")),
];

const s5 = [
  h1("5. Backups and recovery"),
  table(["Question", "Answer"], [
    ["What is backed up?", "The full database and all files uploaded by users"],
    ["When?", "Every night at 03:00 (Tashkent time)"],
    ["Where?", "Encrypted, at an external storage provider — not on the website server"],
    ["How long are backups kept?", "Last 7 days, last 4 weeks, last 6 months"],
    ["Are they tested?", "Yes — every Sunday the latest backup is restored into a temporary copy and checked automatically"],
    ["Maximum data loss (RPO)", "Up to 24 hours (can be reduced to a few hours on request)"],
    ["Time to restore on a new server (RTO)", "Target: under 1 hour"],
    ["Who can read the backups?", "Only someone holding the encryption password. You receive a sealed copy of it"],
  ], [3200, 5826]),
  spacer(),
  callout("Keep the backup password safe", ["Without the encryption password the backups cannot be opened — by anyone, including us. Store the copy we give you in a password manager or a safe."], C.warn),
  h2("If you need data restored"),
  numbered("Tell us what and to which date (for example: \"orders deleted by mistake today at 14:20\").", 1),
  numbered("We confirm which backup will be used and agree on a short maintenance window.", 1),
  numbered("We take a safety copy of the current state first, so the restore itself can be undone.", 1),
  numbered("We restore and confirm in Telegram (♻️ message).", 1),
];

const s6 = [
  h1("6. Security"),
  bullet("Server access only with personal cryptographic keys; passwords and direct administrator login are disabled."),
  bullet("Firewall: only the website ports (80/443) and the protected management port are open."),
  bullet("Automatic blocking of repeated failed login attempts."),
  bullet("Security updates installed automatically every day; you are reminded when a restart is needed."),
  bullet("Monitoring and database are not reachable from the internet."),
  bullet("Automatic releases use a separate key that can only install or roll back a version — nothing else."),
  bullet("All passwords are unique to your project and stored encrypted."),
  bullet("Website traffic is encrypted (HTTPS) with modern security settings and request-rate limits."),
  h2("What we ask from you"),
  bullet("Turn on two-factor authentication for the hosting, domain and email accounts."),
  bullet("Tell us when staff with access leave, so keys can be revoked."),
  bullet("Do not share the monitoring login outside your team."),
];

const s7 = [
  h1("7. Going to production"),
  h2("7.1 Can this be put into production?"),
  p(["Yes. AutoOps is built for production use. Moving to production means installing it on ", b("your own server"), " with ", b("your domain"), ", ", b("your Telegram group"), " and ", b("your backup storage"), ". Everything has been tested on a full demonstration environment; the final installation takes about one working day once the items below are ready."]),
  h2("7.2 Demo hosting versus production"),
  table(["", "Free demo (Render)", "Production (AutoOps on your server)"], [
    ["Purpose", "Show the website quickly", "Run the business"],
    ["Website + HTTPS", "Yes", "Yes"],
    ["Goes to sleep when idle", "Yes, first visit takes ~1 minute", "No, always on"],
    ["Database lifetime", "Limited (free plan expires)", "Permanent"],
    ["Monitoring dashboards", "No", "Yes"],
    ["Telegram alerts", "No", "Yes"],
    ["Self-healing", "No", "Yes"],
    ["Tested backups", "No", "Yes, nightly + weekly restore test"],
    ["Monthly cost", "Free", "Server about €5–25 + storage about $1–3"],
  ], [2400, 3100, 3526]),
  p(i("The free demo is only for presentations. Do not put real customer data on it.")),
  h2("7.3 What we need from you"),
  table(["Item", "Why", "Who provides"], [
    ["Server (2 CPU, 4 GB RAM, 40 GB SSD, Ubuntu)", "Where the website and AutoOps run", "You buy it (we can advise) or give us access to an existing one"],
    ["Domain name and access to its DNS settings", "Your website address and HTTPS", "You"],
    ["Telegram group and the people to add", "Where alerts arrive", "You create it; we add the bot"],
    ["External backup storage account", "Off-site encrypted backups", "You open it (Backblaze B2 or Cloudflare R2); we configure it"],
    ["Your application (code or ready package)", "What we install", "You / your developers"],
    ["Data-location requirements", "Personal-data law of Uzbekistan", "You confirm; we can host everything in Uzbekistan"],
    ["Agreed maintenance window", "For installation and tests", "Together"],
  ], [3100, 2800, 3126]),
  h2("7.4 Launch plan"),
  table(["Day", "What happens", "Your involvement"], [
    ["Day 1", "Collect access, prepare server, install AutoOps", "Provide items from 7.3 (≈30 min)"],
    ["Day 1–2", "Install the website, connect domain and HTTPS, migrate existing data", "Check the site on a temporary address"],
    ["Day 2", "Acceptance checks from section 4", "Join a 45-minute session"],
    ["Launch", "Switch the domain to the new server in the agreed window", "Approve the time"],
    ["Week 1", "Close observation, fine-tune alerts", "Report anything unusual"],
  ], [1500, 4526, 3000]),
  h2("7.5 After launch: support"),
  table(["", "Basic support", "Extended support"], [
    ["Reaction to critical alerts", "1 h in working hours, 4 h at night", "30 min, 24/7"],
    ["Reaction to warnings", "Next working day", "Within 4 hours"],
    ["Security and system updates", "Automatic + monthly maintenance", "Weekly"],
    ["Backup verification", "Weekly (automatic) + quarterly full recovery drill", "Monthly drill"],
    ["Reporting", "Weekly Telegram report, monthly summary", "+ monthly call"],
  ], [2800, 3113, 3113]),
  p(i("Response times describe how quickly we start working on a problem. Uptime target is 99.5–99.9%; problems at the hosting provider or in the application code itself are handled separately.")),
];

const s8 = [
  h1("8. Common alerts explained"),
  table(["Alert", "What it means", "What happens next"], [
    ["Site unavailable", "The website does not answer from outside for over 1 minute", "Automatic recovery is attempted; we investigate immediately"],
    ["Database unavailable", "The website cannot reach its data", "Usually restored automatically within 1–2 minutes"],
    ["Disk almost full", "Storage is over 80% / 90%", "Old temporary files are cleaned automatically; we plan more space if needed"],
    ["High processor / memory load", "The server works at its limit", "We find the cause: traffic peak, faulty task, or need for a bigger server"],
    ["Certificate expires soon", "HTTPS certificate was not renewed", "We fix renewal well before the 14-day deadline"],
    ["Many server errors", "More than 5% of requests fail", "Often after a release — we roll back to the previous version"],
    ["Backup too old / failed", "Last night's backup did not complete", "We run it again the same day"],
    ["Restore test failed", "The weekly test could not restore the backup", "Treated as urgent — a new verified backup is made"],
    ["Self-healing gave up", "Automatic repair failed 3 times in an hour", "A person takes over immediately"],
    ["Container restarted (info)", "A part of the system was restarted automatically", "No action needed unless it repeats"],
  ], [2400, 3300, 3326]),
];

const s9 = [
  h1("9. Frequently asked questions"),
  ...[
    ["Will my website be faster?", "Monitoring shows exactly what is slow, so it can be improved; the platform itself does not slow the site down."],
    ["Do I need to do anything daily?", "No. Glance at the Telegram group; everything critical will be there. Read the weekly report on Mondays."],
    ["What if the whole server is lost?", "A new server is prepared and the latest backup restored — target under one hour."],
    ["Can my developers keep releasing updates?", "Yes. Releases become safer: each new version is checked automatically and rolled back if it fails."],
    ["Can more websites be added later?", "Yes, several projects can share one server, each isolated and monitored."],
    ["Who owns everything?", "You do: the server, accounts, passwords and configuration. If we stop working together, everything is handed over within 5 working days."],
    ["Can everything stay in Uzbekistan?", "Yes. Server and backups can be placed with a local provider."],
  ].flatMap(([q, a]) => [
    new Paragraph({ spacing: { before: 160, after: 40 }, children: [new TextRun({ text: q, bold: true, color: C.primary })] }),
    p(a),
  ]),
  spacer(),
  callout("Contacts", ["Support: <name>", "Telegram: <@username>   Phone: <+998 ...>", "Urgent issues: write in the alerts group or call."]),
];

// ---------------------------------------------------------------- document
const doc = new Document({
  creator: "AutoOps",
  title: "AutoOps — Client guide",
  description: "Features, verification and production launch",
  styles: {
    default: { document: { run: { font: FONT, size: 22, color: C.text } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 34, bold: true, font: FONT, color: C.primary },
        paragraph: { spacing: { before: 120, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, font: FONT, color: C.accent },
        paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 1 } },
    ],
  },
  numbering: {
    config: [
      { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
      { reference: "steps", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
    ],
  },
  features: { updateFields: true },
  sections: [{
    properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: "AutoOps — Client guide", size: 18, color: C.muted })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ children: ["Page ", PageNumber.CURRENT, " of ", PageNumber.TOTAL_PAGES], size: 18, color: C.muted })] })] }) },
    children: [...cover, ...toc, ...s1, ...s2, ...s3, ...s4, ...s5, ...s6, ...s7, ...s8, ...s9],
  }],
});

Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(OUT, buf); console.log("wrote", OUT, buf.length, "bytes"); });
