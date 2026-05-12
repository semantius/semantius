import type { CollectionEntry } from 'astro:content';

export interface NavNode {
  segment: string;
  doc?: CollectionEntry<'docs'>;
  children: NavNode[];
  order: number;
  navTitle: string;
  path: string;
}

function defaultLabel(segment: string): string {
  return segment.charAt(0).toUpperCase() + segment.slice(1).replace(/-/g, ' ');
}

export function buildDocsTree(docs: CollectionEntry<'docs'>[]): NavNode {
  const root: NavNode = {
    segment: '',
    children: [],
    order: -Infinity,
    navTitle: '',
    path: '/docs',
  };

  for (const doc of docs) {
    const fullSlug = doc.id.replace(/\.[^/.]+$/, '');
    const parts = fullSlug.split('/');
    let cursor = root;
    let segPath = '';

    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i];
      const isLast = i === parts.length - 1;

      // A file named `index` attaches its doc to the parent folder node rather
      // than creating a new child. This lets a folder also be a page.
      if (isLast && seg === 'index') {
        cursor.doc = doc;
        cursor.order = doc.data.order ?? cursor.order;
        cursor.navTitle = doc.data.navTitle ?? doc.data.title ?? cursor.navTitle;
        break;
      }

      segPath = segPath ? `${segPath}/${seg}` : seg;
      let child = cursor.children.find((c) => c.segment === seg);
      if (!child) {
        child = {
          segment: seg,
          children: [],
          order: 99,
          navTitle: defaultLabel(seg),
          path: `/docs/${segPath}`,
        };
        cursor.children.push(child);
      }
      if (isLast) {
        child.doc = doc;
        child.order = doc.data.order ?? 99;
        child.navTitle = doc.data.navTitle ?? doc.data.title;
      }
      cursor = child;
    }
  }

  sortRecursive(root);
  return root;
}

function sortRecursive(node: NavNode) {
  node.children.sort((a, b) => {
    if (a.order !== b.order) return a.order - b.order;
    return a.navTitle.localeCompare(b.navTitle);
  });
  for (const c of node.children) sortRecursive(c);
}

// Depth-first flattening in display order: each node with a doc appears
// before its children, mirroring how the user reads the nav top-to-bottom.
export function flattenTree(node: NavNode): NavNode[] {
  const acc: NavNode[] = [];
  walk(node, acc);
  return acc;
}

function walk(node: NavNode, acc: NavNode[]) {
  if (node.doc && node.path !== '/docs') acc.push(node);
  for (const c of node.children) walk(c, acc);
}

// Serializable shape for passing to React (no Astro CollectionEntry refs).
export interface SerializableNavNode {
  segment: string;
  hasDoc: boolean;
  children: SerializableNavNode[];
  navTitle: string;
  path: string;
}

export function serializeTree(node: NavNode): SerializableNavNode {
  return {
    segment: node.segment,
    hasDoc: !!node.doc,
    children: node.children.map(serializeTree),
    navTitle: node.navTitle,
    path: node.path,
  };
}

// Find the topmost ancestor (just under root) of the node matching a path.
export function findTopAncestor(root: NavNode, path: string): NavNode | null {
  for (const child of root.children) {
    if (containsPath(child, path)) return child;
  }
  return null;
}

function containsPath(node: NavNode, path: string): boolean {
  if (node.path === path) return true;
  return node.children.some((c) => containsPath(c, path));
}
