import { marked } from 'marked';

function stripSectionNumbers(md: string): string {
	return md.replace(/^(#{1,6})\s+\d+(?:\.\d+)*\.\s+/gm, '$1 ');
}

export function extractOverview(body: string): string {
	const start = body.search(/^## 1\. Overview\b/m);
	const end = body.search(/^## 2\. /m);
	if (start === -1) return '';
	return body
		.slice(start, end === -1 ? body.length : end)
		.replace(/^## 1\. Overview\b.*$/m, '')
		.trim();
}

export function extractSubsetMarkdown(body: string): string {
	const summaryStart = body.search(/^## 2\. Entity summary\b/m);
	const entitiesStart = body.search(/^## 3\. Entities\b/m);
	if (summaryStart === -1) return '';
	let md = body
		.slice(summaryStart, entitiesStart === -1 ? body.length : entitiesStart)
		.trim();
	md = stripSectionNumbers(md);
	// "Entity-relationship diagram" -> "Entity relationships": readers can see
	// it's a diagram, but the label still says what it shows.
	md = md.replace(/^(#{1,6}\s+Entity[- ]relationship)s?\s+diagram\s*$/gim, '$1s');
	return md;
}

export function renderSubsetHtml(md: string): string {
	if (!md) return '';
	let html = marked.parse(md, { async: false }) as string;
	// marked HTML-encodes the content of code blocks. Unescape the mermaid
	// source so that < and > remain as raw characters in the HTML output
	// (makes view-source copy-paste of diagram definitions easier). The
	// @mostlylucid/mermaid-enhancements client reads via textContent which
	// handles both escaped and unescaped content correctly.
	html = html.replace(
		/<pre><code class="language-mermaid">([\s\S]*?)<\/code><\/pre>/g,
		(_, code) => {
			// Decode specific entities first, then &amp; last to avoid
			// double-decoding (e.g. &amp;lt; -> &lt; not <).
			// Only these three entities appear in mermaid diagram content
			// that marked encodes; &quot;/&#39; do not appear in mermaid
			// node or edge syntax so they are intentionally excluded.
			const raw = code
				.replace(/&lt;/g, '<')
				.replace(/&gt;/g, '>')
				.replace(/&amp;/g, '&');
			return `<pre class="mermaid">${raw}</pre>`;
		},
	);
	return html;
}
