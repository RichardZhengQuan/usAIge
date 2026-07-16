const downloadUrl = "/usAIge-0.1.13-alpha.dmg";

const features = [
  {
    number: "01",
    title: "Every tool, at a glance",
    copy: "See live Codex limits beside compatible team services you connect with one link.",
  },
  {
    number: "02",
    title: "Present, never in the way",
    copy: "The floating rail stays above ordinary windows, remembers each display, and fades back when idle.",
  },
  {
    number: "03",
    title: "Private by design",
    copy: "Local Codex stays local. Optional remote tokens live in Keychain and go only to endpoints you configure.",
  },
  {
    number: "04",
    title: "Made to fit your desk",
    copy: "Choose visible tools and quotas, tune the rail, and let usAIge start automatically when you log in.",
  },
];

function QuotaRing({ value, label }: { value: number; label: string }) {
  return (
    <div className="quota-ring" style={{ "--quota": `${value * 3.6}deg` } as React.CSSProperties}>
      <div className="quota-ring__center">
        <strong>{value}%</strong>
        <span>{label}</span>
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <main>
      <nav className="nav shell" aria-label="Main navigation">
        <a className="brand" href="#top" aria-label="usAIge home">
          <img src="/app-icon.png" alt="" />
          <span>us<span>AI</span>ge</span>
        </a>
        <div className="nav__links">
          <a href="#features">Features</a>
          <a href="#privacy">Privacy</a>
          <a className="nav__download" href={downloadUrl} download>Download <span aria-hidden="true">↘</span></a>
        </div>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero__copy">
          <p className="eyebrow"><span /> Native macOS utility · Public alpha</p>
          <h1>Know your<br />AI <em>limits.</em></h1>
          <p className="hero__lede">
            usAIge is a quiet floating rail for your real AI usage—local Codex and remote tools, always visible and instantly readable.
          </p>
          <div className="hero__actions">
            <a className="button button--primary" href={downloadUrl} download>
              <span className="button__icon" aria-hidden="true">↓</span>
              <span><strong>Download for macOS</strong><small>v0.1.13 alpha · macOS 11+ · Apple silicon</small></span>
            </a>
            <a className="text-link" href="#install">How to install <span aria-hidden="true">→</span></a>
          </div>
        </div>

        <div className="hero__visual" aria-label="Preview of the usAIge floating usage rail">
          <div className="orb orb--one" />
          <div className="orb orb--two" />
          <div className="desktop-card">
            <div className="desktop-card__top"><i /><i /><i /><span>Focused work</span></div>
            <div className="desktop-card__lines"><b /><b /><b /><b /></div>
          </div>
          <div className="usage-rail">
            <div className="usage-rail__brand"><img src="/app-icon.png" alt="" /><span>usAIge</span><i>live</i></div>
            <div className="quota-row">
              <QuotaRing value={72} label="5 hour" />
              <div><strong>Codex</strong><span>2h 38m until reset</span></div>
              <b>72%</b>
            </div>
            <div className="quota-row">
              <QuotaRing value={46} label="7 day" />
              <div><strong>Weekly</strong><span>3d 14h until reset</span></div>
              <b>46%</b>
            </div>
            <div className="usage-rail__foot"><span>Updated now</span><span aria-hidden="true">⌁</span></div>
          </div>
          <p className="visual-note"><span>Real data</span> from local Codex and endpoints you add</p>
        </div>
      </section>

      <section className="proof-strip" aria-label="Product highlights">
        <div className="shell proof-strip__inner">
          <span>5-hour window</span><i />
          <span>7-day window</span><i />
          <span>Starts at login</span><i />
          <span>Remote tools</span>
        </div>
      </section>

      <section className="features shell" id="features">
        <div className="section-heading">
          <p className="eyebrow"><span /> What it does</p>
          <h2>Your limits belong<br />in your <em>periphery.</em></h2>
          <p>Stay in flow without opening a dashboard or wondering when your quota resets.</p>
        </div>
        <div className="feature-grid">
          {features.map((feature) => (
            <article className="feature" key={feature.number}>
              <span className="feature__number">{feature.number}</span>
              <div className={`feature__glyph feature__glyph--${feature.number}`} aria-hidden="true"><i /><i /><i /></div>
              <h3>{feature.title}</h3>
              <p>{feature.copy}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="privacy shell" id="privacy">
        <div className="privacy__mark" aria-hidden="true"><span>✓</span></div>
        <div>
          <p className="eyebrow"><span /> Privacy without fine print</p>
          <h2>You choose<br /><em>every source.</em></h2>
        </div>
        <div className="privacy__copy">
          <p>usAIge reads documented rate-limit data from local Codex and only the remote endpoints you explicitly add. It does not scrape websites, inspect screen pixels, or invent missing values.</p>
          <ul>
            <li><span>✓</span> No browser cookies read</li>
            <li><span>✓</span> No separate account login</li>
            <li><span>✓</span> Remote tokens stay in Keychain</li>
            <li><span>✓</span> No analytics or tracking</li>
          </ul>
        </div>
      </section>

      <section className="install shell" id="install">
        <div>
          <p className="eyebrow"><span /> Ready when you are</p>
          <h2>One small rail.<br /><em>Zero surprises.</em></h2>
        </div>
        <ol className="install__steps">
          <li><span>1</span><div><strong>Download the alpha</strong><p>Get the macOS disk image. It is an early, ad-hoc signed build.</p></div></li>
          <li><span>2</span><div><strong>Drag into Applications</strong><p>Open the disk image and move usAIge to the Applications shortcut.</p></div></li>
          <li><span>3</span><div><strong>Control-click to open once</strong><p>Choose Open on first launch, then optionally enable “Open usAIge at login” in Settings.</p></div></li>
        </ol>
        <div className="install__cta">
          <a className="button button--primary" href={downloadUrl} download>
            <span className="button__icon" aria-hidden="true">↓</span>
            <span><strong>Download usAIge</strong><small>v0.1.13 alpha · macOS 11 or later · Apple silicon</small></span>
          </a>
          <a className="checksum" href="/usAIge-0.1.13-alpha.dmg.sha256" download>SHA-256 checksum</a>
        </div>
      </section>

      <footer className="footer shell">
        <a className="brand" href="#top"><img src="/app-icon.png" alt="" /><span>us<span>AI</span>ge</span></a>
        <p>Built for people who would rather make things than monitor dashboards.</p>
        <span>Public alpha · 2026</span>
      </footer>
    </main>
  );
}
