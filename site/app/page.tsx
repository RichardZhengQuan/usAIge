import { SectionLink } from "./section-link";

const basePath = "/project/usaige";
const assetUrl = (path: string) => `${basePath}/${path}`;
const releaseBaseUrl = "https://usaige-macos.richardqz.chatgpt.site";
const downloadUrl = `${releaseBaseUrl}/usAIge-0.2.4-alpha.dmg`;
const checksumUrl = `${releaseBaseUrl}/usAIge-0.2.4-alpha.dmg.sha256`;

const statusColors = [
  { key: "error", label: "Error", color: "#ff5284", detail: "Always wins" },
  { key: "complete", label: "Recent completion", color: "#62dc8b", detail: "Fresh result" },
  { key: "input", label: "Needs input", color: "#ffc75b", detail: "Your turn" },
  { key: "running", label: "Running", color: "#5790ff", detail: "Agent at work" },
];

const usageEffects = [
  ["Live dual windows", "See Codex’s short and weekly limits together, with real reset times and remaining percentages."],
  ["Priority color system", "Pink error, green recent completion, yellow needs input, blue running, and no light when idle."],
  ["Critical quota signal", "Five usage bands culminate in a focused deep-red remaining arc while the unused track stays transparent."],
  ["Hover focus", "The rail returns to full opacity, reveals controls, refreshes stale data, and shows detailed reset context."],
  ["Your size and opacity", "Set resting opacity from 10–100% and scale the compact rail from 50–250%."],
  ["Local plus connected tools", "Read local Codex automatically and add compatible read-only HTTPS sources with Keychain tokens."],
];

export default function Home() {
  return (
    <main>
      <nav className="nav shell" aria-label="Main navigation">
        <SectionLink className="brand" targetId="top" aria-label="usAIge home">
          <img src={assetUrl("app-icon.png")} alt="" />
          <span>us<span>AI</span>ge</span>
        </SectionLink>
        <div className="nav__links">
          <SectionLink targetId="agent-status">Agent status</SectionLink>
          <SectionLink targetId="usage-effects">Usage effects</SectionLink>
          <SectionLink targetId="product">Product</SectionLink>
          <a className="nav__download" href={downloadUrl} download>Download <span aria-hidden="true">↘</span></a>
        </div>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero__copy">
          <p className="eyebrow"><span /> v0.2.4 · Native macOS utility</p>
          <h1>Your AI work,<br /><em>still breathing.</em></h1>
          <p className="hero__lede">
            usAIge keeps usage limits and Codex task health in one quiet floating rail. One glance tells you whether agents are running, finished, waiting, or broken.
          </p>
          <div className="hero__actions">
            <a className="button button--primary" href={downloadUrl} download>
              <span className="button__icon" aria-hidden="true">↓</span>
              <span><strong>Download for macOS</strong><small>v0.2.4 alpha · macOS 11+ · Apple silicon</small></span>
            </a>
            <SectionLink className="text-link" targetId="agent-status">See the status system <span aria-hidden="true">→</span></SectionLink>
          </div>
        </div>

        <div className="hero__visual" aria-label="Current usAIge HUD showing a blue breathing agent status">
          <div className="product-stage">
            <div className="product-stage__label"><span /> Live product capture</div>
            <img src={assetUrl("product-hud-status.png")} alt="usAIge Codex limit ring with a blue running-status glory" />
            <div className="product-stage__note">
              <strong>One light for every task.</strong>
              <span>Breathes from a thin halo to a stronger status glow.</span>
            </div>
          </div>
        </div>
      </section>

      <section className="proof-strip" aria-label="Release highlights">
        <div className="shell proof-strip__inner">
          <span>Up to 100 active tasks</span><i />
          <span>Click back to the task</span><i />
          <span>10–100% resting opacity</span><i />
          <span>50–250% HUD scale</span>
        </div>
      </section>

      <section className="status-system shell" id="agent-status">
        <div className="section-heading section-heading--stacked">
          <p className="eyebrow"><span /> Aggregate agent status</p>
          <h2>One circle.<br /><em>Every session.</em></h2>
          <p>usAIge watches up to 100 active Codex tasks and turns the highest-priority state into one breathing glory behind the Codex limit ring.</p>
        </div>

        <div className="status-priority">
          <p className="status-priority__label">Priority order</p>
          {statusColors.map((status, index) => (
            <article className="status-card" key={status.key} style={{ "--status": status.color } as React.CSSProperties}>
              <span className="status-card__order">0{index + 1}</span>
              <span className="status-card__light" aria-hidden="true"><i /></span>
              <div><strong>{status.label}</strong><small>{status.detail}</small></div>
            </article>
          ))}
        </div>

        <div className="click-back">
          <div><span>When the light breathes</span><strong>Click the ring to reopen the exact task creating that color.</strong></div>
          <i aria-hidden="true">→</i>
          <div><span>When there is no active task</span><strong>Click the same logo to return to the AI tool.</strong></div>
        </div>
      </section>

      <section className="effects shell" id="usage-effects">
        <div className="section-heading">
          <p className="eyebrow"><span /> Every usage effect</p>
          <h2>Quiet at rest.<br /><em>Clear on demand.</em></h2>
          <p>The compact rail stays readable without becoming another dashboard to manage.</p>
        </div>
        <div className="effects-grid">
          {usageEffects.map(([title, copy], index) => (
            <article className="effect" key={title}>
              <span>0{index + 1}</span>
              <h3>{title}</h3>
              <p>{copy}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="product shell" id="product">
        <div className="section-heading section-heading--stacked">
          <p className="eyebrow"><span /> Current product</p>
          <h2>Only what you<br /><em>choose to see.</em></h2>
          <p>Use the native Settings window to pick tools and usage types, reorder them, and tune the rail for your desk.</p>
        </div>
        <figure className="product-shot product-shot--settings">
          <img src={assetUrl("product-settings.png")} alt="usAIge Settings showing active and connected AI tools" />
          <figcaption><strong>Native macOS Settings</strong><span>Choose tools, usage windows, scale, opacity, startup, and updates.</span></figcaption>
        </figure>
        <figure className="product-shot product-shot--hud">
          <div className="product-shot__media product-shot__media--hud">
            <img src={assetUrl("product-hud-status.png")} alt="Current usAIge floating Codex HUD with blue status glory" />
          </div>
          <figcaption><strong>The live floating rail</strong><span>Usage ring, agent state, and click-back target in one place.</span></figcaption>
        </figure>
      </section>

      <section className="privacy shell" id="privacy">
        <div className="privacy__mark" aria-hidden="true"><span>✓</span></div>
        <div>
          <p className="eyebrow"><span /> Privacy without fine print</p>
          <h2>You choose<br /><em>every source.</em></h2>
        </div>
        <div className="privacy__copy">
          <p>usAIge reads local Codex state and only the remote endpoints you explicitly add. Optional iPhone Sync relays the latest normalized percentages and reset times—never provider credentials, prompts, or task content.</p>
          <ul>
            <li><span>✓</span> No browser cookies read</li>
            <li><span>✓</span> No separate account login</li>
            <li><span>✓</span> Remote tokens stay in Keychain</li>
            <li><span>✓</span> Relay data is deleted when unlinked</li>
            <li><span>✓</span> No app activity tracking</li>
          </ul>
        </div>
      </section>

      <section className="install shell" id="install">
        <div>
          <p className="eyebrow"><span /> Ready when you are</p>
          <h2>One small rail.<br /><em>Zero surprises.</em></h2>
        </div>
        <ol className="install__steps">
          <li><span>1</span><div><strong>Download the alpha</strong><p>Get the newest macOS disk image and verified checksum.</p></div></li>
          <li><span>2</span><div><strong>Drag into Applications</strong><p>Open the disk image and move usAIge to the Applications shortcut.</p></div></li>
          <li><span>3</span><div><strong>Control-click to open once</strong><p>Choose Open on first launch, then optionally enable startup in Settings.</p></div></li>
        </ol>
        <div className="install__cta">
          <a className="button button--primary" href={downloadUrl} download>
            <span className="button__icon" aria-hidden="true">↓</span>
            <span><strong>Download usAIge</strong><small>v0.2.4 alpha · macOS 11 or later · Apple silicon</small></span>
          </a>
          <a className="checksum" href={checksumUrl} download>SHA-256 checksum</a>
        </div>
      </section>

      <footer className="footer shell">
        <SectionLink className="brand" targetId="top"><img src={assetUrl("app-icon.png")} alt="" /><span>us<span>AI</span>ge</span></SectionLink>
        <p>Built for people who would rather make things than monitor dashboards.</p>
        <span>v0.2.4 public alpha · 2026</span>
      </footer>
    </main>
  );
}
