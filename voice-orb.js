// Reusable <voice-orb> web component. Drop into any page:
//   <script src="voice-orb.js" type="module"></script>
//   <voice-orb dots="1800" gain="0.5" spin="0.12"></voice-orb>
class VoiceOrb extends HTMLElement {
  constructor() {
    super();
    this._root = this.attachShadow({ mode: 'open' });
    this._container = document.createElement('div');
    this._container.style.width = '100%';
    this._container.style.height = '100%';
    this._root.appendChild(this._container);
    this._rendered = false;
  }
  static get observedAttributes() { return ['dots','gain','spin','colorby','mode']; }
  attributeChangedCallback() { if (this._rendered) this._render(); }
  async connectedCallback() {
    if (this._rendered) return;
    // size container to element
    const w = this.getAttribute('width') || '360';
    const h = this.getAttribute('height') || '360';
    this.style.display = 'inline-block';
    this.style.width = w + 'px';
    this.style.height = h + 'px';
    this._container.style.width = '100%';
    this._container.style.height = '100%';
    try {
      const React = (await import('https://esm.sh/react@19')).default;
      const { createRoot } = await import('https://esm.sh/react-dom@19/client');
      const { VoiceOrb: Orb } = await import('https://esm.sh/@thecharlesponti/waveform-react');
      this._React = React;
      this._createRoot = createRoot;
      this._Orb = Orb;
      this._rootInstance = createRoot(this._container);
      this._rendered = true;
      this._render();
    } catch (e) {
      this._container.textContent = 'Orb failed to load: ' + e;
    }
  }
  _render() {
    const dots = parseInt(this.getAttribute('dots') || '1800', 10);
    const gain = parseFloat(this.getAttribute('gain') || '0.5');
    const spin = parseFloat(this.getAttribute('spin') || '0.12');
    const colorBy = this.getAttribute('colorby') || null;
    const mode = this.getAttribute('mode') || 'spectrum';
    this._rootInstance.render(
      this._React.createElement(this._Orb, { dots, gain, spin, colorBy, mode, style: { width: '100%', height: '100%' } })
    );
  }
  disconnectedCallback() {
    if (this._rootInstance) this._rootInstance.unmount();
  }
}
customElements.define('voice-orb', VoiceOrb);
