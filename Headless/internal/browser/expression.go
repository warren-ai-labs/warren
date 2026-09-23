package browser

import "encoding/json"

// The expressions in this file run inside the page. They are plain functions
// evaluated by Runtime.evaluate, so they must not reference anything outside
// themselves and must not use template literals that would need escaping.
//
// Every expression returns JSON so the Go side can decode one shape and reason
// about a missing value instead of parsing a string.

// pointExpression finds an element by selector or by its visible text and
// returns its centre in viewport coordinates.
//
// The element is scrolled into view first, because an element below the fold has
// a rect outside the viewport and clicking that coordinate hits whatever is
// actually there instead.
func pointExpression(selector, text string) string {
	selectorJSON, textJSON := jsString(selector), jsString(text)
	return `(() => {
  ` + describeFunction() + `
  const byText = (root, wanted) => {
    const wantedLower = wanted.trim().toLowerCase();
    if (!wantedLower) return null;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let best = null;
    while (walker.nextNode()) {
      const node = walker.currentNode;
      const own = Array.from(node.childNodes)
        .filter((child) => child.nodeType === Node.TEXT_NODE)
        .map((child) => child.textContent.trim())
        .join(' ')
        .toLowerCase();
      if (!own) continue;
      if (own === wantedLower || own.includes(wantedLower)) {
        if (!best || own.length < best.own.length) best = { node, own };
      }
    }
    return best ? best.node : null;
  };
  const element = ` + selectorJSON + `
    ? document.querySelector(` + selectorJSON + `)
    : byText(document.body, ` + textJSON + `);
  if (!element) return JSON.stringify({ found: false });
  const rect = element.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) {
    return JSON.stringify({ found: true, visible: false, selector: describe(element) });
  }
  element.scrollIntoView({ block: 'center', inline: 'center' });
  const scrolled = element.getBoundingClientRect();
  return JSON.stringify({
    found: true,
    visible: true,
    x: scrolled.left + scrolled.width / 2,
    y: scrolled.top + scrolled.height / 2,
    selector: describe(element)
  });
})()`
}

// describe builds a stable, unique selector for one element so an agent can
// address it again in a later action.
func describeFunction() string {
	return `function describe(element) {
  const parts = [];
  let node = element;
  while (node && node.nodeType === Node.ELEMENT_NODE && parts.length < 5) {
    let part = node.tagName.toLowerCase();
    if (node.id) {
      part += '#' + node.id;
      parts.unshift(part);
      break;
    }
    const parent = node.parentElement;
    if (parent) {
      const siblings = Array.from(parent.children).filter((child) => child.tagName === node.tagName);
      if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
    }
    parts.unshift(part);
    node = node.parentElement;
  }
  return parts.join(' > ');
}`
}

// snapshotExpression flattens the page into the node list an agent reads.
//
// It is a flattened list rather than a tree because an agent consuming a tree has
// to re-flatten it to find anything, and because the node count is what a caller
// needs in order to bound its own context.
func snapshotExpression(maxNodes int, interactiveOnly bool) string {
	interactive := "false"
	if interactiveOnly {
		interactive = "true"
	}
	return `(() => {
  ` + describeFunction() + `
  const interactiveSelector = 'a[href], button, input, select, textarea, [role=button], [role=link], [role=textbox], [role=checkbox], [role=combobox], [role=menuitem], [tabindex], [contenteditable=true], summary, label';
  const roleFor = (element) => {
    const explicit = element.getAttribute('role');
    if (explicit) return explicit;
    switch (element.tagName) {
      case 'A': return element.hasAttribute('href') ? 'link' : '';
      case 'BUTTON': return 'button';
      case 'INPUT': {
        const type = (element.getAttribute('type') || 'text').toLowerCase();
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'submit' || type === 'button') return 'button';
        return 'textbox';
      }
      case 'SELECT': return 'combobox';
      case 'TEXTAREA': return 'textbox';
      case 'IMG': return 'img';
      case 'NAV': return 'navigation';
      case 'MAIN': return 'main';
      default: return '';
    }
  };
  const isVisible = (element) => {
    const style = getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const interactiveFor = (element) => element.matches(interactiveSelector);
  const nodes = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
  let seen = 0;
  while (walker.nextNode()) {
    const element = walker.currentNode;
    if (element.tagName === 'SCRIPT' || element.tagName === 'STYLE' || element.tagName === 'NOSCRIPT') continue;
    const interactive = interactiveFor(element);
    if (` + interactive + ` && !interactive) continue;
    seen += 1;
    if (seen > ` + itoa(maxNodes) + `) break;
    const rect = element.getBoundingClientRect();
    const text = Array.from(element.childNodes)
      .filter((child) => child.nodeType === Node.TEXT_NODE)
      .map((child) => child.textContent.replace(/\s+/g, ' ').trim())
      .join(' ')
      .slice(0, 200);
    const node = {
      selector: describe(element),
      tag: element.tagName.toLowerCase(),
      role: roleFor(element),
      interactive: interactive,
      enabled: !element.disabled,
      visible: isVisible(element)
    };
    if (text) node.text = text;
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      if (element.type === 'checkbox' || element.type === 'radio') node.checked = element.checked;
      if (element.value) node.value = element.value.slice(0, 200);
    }
    if (interactive && isVisible(element)) {
      node.rect = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    }
    nodes.push(node);
  }
  return JSON.stringify({
    url: location.href,
    title: document.title,
    nodes: nodes,
    truncated: seen >= ` + itoa(maxNodes) + `
  });
})()`
}

// waitExpression reports whether a wait condition is satisfied.
func waitExpression(selector, text, url, state string) string {
	selectorJSON, textJSON, urlJSON, stateJSON := jsString(selector), jsString(text), jsString(url), jsString(state)
	return `(() => {
  const state = ` + stateJSON + `;
  const url = ` + urlJSON + `;
  if (url && state === 'url') {
    return JSON.stringify({ ready: location.href.includes(url) || document.title.includes(url) });
  }
  const byText = (wanted) => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    const lower = wanted.trim().toLowerCase();
    while (walker.nextNode()) {
      const node = walker.currentNode;
      const own = Array.from(node.childNodes)
        .filter((child) => child.nodeType === Node.TEXT_NODE)
        .map((child) => child.textContent.trim())
        .join(' ');
      if (own.toLowerCase().includes(lower)) return node;
    }
    return null;
  };
  const element = ` + selectorJSON + ` ? document.querySelector(` + selectorJSON + `) : (` + textJSON + ` ? byText(` + textJSON + `) : null);
  if (!element) return JSON.stringify({ ready: state === 'detached' });
  const style = getComputedStyle(element);
  const visible = style.display !== 'none' && style.visibility !== 'hidden';
  const ready = state === 'hidden' ? !visible : visible;
  return JSON.stringify({ ready: ready });
})()`
}

// clearFieldExpression empties one input and fires the events a framework needs
// to notice.
func clearFieldExpression(selector string) string {
	selectorJSON := jsString(selector)
	return `(() => {
  const element = ` + selectorJSON + ` ? document.querySelector(` + selectorJSON + `) : document.activeElement;
  if (!element) return JSON.stringify({ cleared: false });
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  if (element.tagName === 'TEXTAREA' && HTMLTextAreaElement.prototype.value) {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(element, '');
  } else if (setter && setter.set) {
    setter.set.call(element, '');
  } else {
    element.value = '';
  }
  element.dispatchEvent(new Event('input', { bubbles: true }));
  element.dispatchEvent(new Event('change', { bubbles: true }));
  return JSON.stringify({ cleared: true });
})()`
}

// selectExpression chooses options in a select and dispatches the events a
// controlled component listens for.
func selectExpression(selector string, values []string) string {
	selectorJSON := jsString(selector)
	encodedValues := jsArray(values)
	return `(() => {
  const element = document.querySelector(` + selectorJSON + `);
  if (!element || element.tagName !== 'SELECT') return JSON.stringify({ found: false });
  const wanted = ` + encodedValues + `;
  const selected = [];
  for (const option of Array.from(element.options)) {
    option.selected = wanted.indexOf(option.value) !== -1;
    if (option.selected) selected.push(option.value);
  }
  element.dispatchEvent(new Event('input', { bubbles: true }));
  element.dispatchEvent(new Event('change', { bubbles: true }));
  return JSON.stringify({ found: true, selected: selected });
})()`
}

// focusExpression focuses one field without clicking it.
//
// Focusing matters because Input.insertText delivers text to whatever element
// holds focus, so a type action that never focused anything would type into the
// body. Focusing in the page is preferred over a synthetic click: a click on a
// label or a checkbox has side effects that a type action never asked for.
func focusExpression(selector string) string {
	selectorJSON := jsString(selector)
	return `(() => {
  const element = ` + selectorJSON + ` ? document.querySelector(` + selectorJSON + `) : document.activeElement;
  if (!element || typeof element.focus !== 'function') return JSON.stringify({ focused: false });
  element.focus();
  if (typeof element.select === 'function') {
    try { element.select(); } catch (error) { /* not all focusable elements are selectable */ }
  }
  return JSON.stringify({ focused: document.activeElement === element });
})()`
}

// scrollIntoViewExpression scrolls one element to the centre of the viewport.
func scrollIntoViewExpression(selector, text string) string {
	selectorJSON, textJSON := jsString(selector), jsString(text)
	return `(() => {
  const byText = (wanted) => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    const lower = wanted.trim().toLowerCase();
    while (walker.nextNode()) {
      const node = walker.currentNode;
      const own = Array.from(node.childNodes)
        .filter((child) => child.nodeType === Node.TEXT_NODE)
        .map((child) => child.textContent.trim())
        .join(' ');
      if (own.toLowerCase().includes(lower)) return node;
    }
    return null;
  };
  const element = ` + selectorJSON + ` ? document.querySelector(` + selectorJSON + `) : byText(` + textJSON + `);
  if (!element) return JSON.stringify({ found: false });
  element.scrollIntoView({ block: 'center', inline: 'center' });
  return JSON.stringify({ found: true });
})()`
}

// jsString encodes a Go string as a JavaScript string literal.
func jsString(value string) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return `""`
	}
	return string(encoded)
}

// jsArray encodes a Go string slice as a JavaScript array literal.
func jsArray(values []string) string {
	encoded, err := json.Marshal(values)
	if err != nil {
		return "[]"
	}
	return string(encoded)
}
