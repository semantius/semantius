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
	// astro-mermaid only post-processes markdown that goes through Astro's own
	// pipeline. Our subset is rendered via `marked`, so reshape the mermaid
	// code blocks into the `<pre class="mermaid">` form the integration's
	// client script picks up.
	html = html.replace(
		/<pre><code class="language-mermaid">([\s\S]*?)<\/code><\/pre>/g,
		(_, code) => `<pre class="mermaid">${code}</pre>`,
	);
	return html;
}
