import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { X, ChevronDown, ListTree } from 'lucide-react';

function NavBranch({ node, currentPath, depth, onNavigate }) {
  const isExact = currentPath === node.path;
  const hasChildren = node.children.length > 0;

  // Open the branch if it contains the current page.
  const containsCurrent = (n) => {
    if (n.path === currentPath) return true;
    return n.children.some(containsCurrent);
  };
  const [open, setOpen] = useState(() => containsCurrent(node));

  if (!hasChildren) {
    return (
      <li>
        <a
          href={node.path}
          onClick={onNavigate}
          className={`flex items-center rounded-md px-3 py-1.5 text-sm transition-colors ${
            isExact
              ? 'text-primary font-semibold'
              : 'text-foreground/60 hover:text-foreground hover:bg-foreground/5'
          }`}
        >
          {node.navTitle}
        </a>
      </li>
    );
  }

  const isTop = depth === 0;

  return (
    <li>
      <div
        className={`flex items-center rounded-md hover:bg-foreground/5 transition-colors ${
          isExact ? 'bg-foreground/5' : ''
        }`}
      >
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-label={open ? 'Collapse section' : 'Expand section'}
          className="flex items-center justify-center w-7 h-7 text-foreground/60 hover:text-foreground"
        >
          <ChevronDown
            className={`w-4 h-4 transition-transform ${open ? '' : '-rotate-90'}`}
          />
        </button>
        {node.hasDoc ? (
          <a
            href={node.path}
            onClick={onNavigate}
            className={`flex-1 truncate px-2 py-1.5 text-sm tracking-wide ${
              isTop ? 'font-semibold' : ''
            } ${
              isExact
                ? 'text-primary'
                : isTop
                  ? 'text-foreground/80 hover:text-foreground'
                  : 'text-foreground/70 hover:text-foreground'
            }`}
          >
            {node.navTitle}
          </a>
        ) : (
          <span
            className={`flex-1 truncate px-2 py-1.5 text-sm tracking-wide cursor-pointer ${
              isTop ? 'font-semibold text-foreground/80' : 'text-foreground/70'
            }`}
            onClick={() => setOpen((o) => !o)}
          >
            {node.navTitle}
          </span>
        )}
      </div>
      {open && (
        <ul className="list-none p-0 m-0 mt-1 pl-3 ml-2 border-l border-foreground/10 space-y-1">
          {node.children.map((child) => (
            <NavBranch
              key={child.path}
              node={child}
              currentPath={currentPath}
              depth={depth + 1}
              onNavigate={onNavigate}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

export default function MobileDocsMenu({ tree, currentPath }) {
  const [isOpen, setIsOpen] = useState(false);

  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = 'unset';
    }
  }, [isOpen]);

  const normalizedCurrentPath =
    currentPath.endsWith('/') && currentPath.length > 1
      ? currentPath.slice(0, -1)
      : currentPath;

  const close = () => setIsOpen(false);

  return (
    <>
      <button
        onClick={() => setIsOpen(true)}
        className="flex lg:hidden items-center gap-2 px-3 py-1.5 text-sm font-medium text-foreground/70 bg-foreground/5 rounded-full hover:text-foreground transition-colors"
        aria-label="Open Documentation Navigation"
      >
        <ListTree className="w-4 h-4" />
        Docs Menu
      </button>

      <AnimatePresence>
        {isOpen && (
          <>
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              onClick={close}
              className="fixed inset-0 bg-background/60 backdrop-blur-sm z-80"
              aria-hidden="true"
            />

            <motion.div
              initial={{ x: '-100%' }}
              animate={{ x: 0 }}
              exit={{ x: '-100%' }}
              transition={{ type: 'spring', damping: 25, stiffness: 200 }}
              className="fixed inset-y-0 left-0 w-[85%] max-w-sm bg-background border-r border-foreground/10 z-90 shadow-2xl flex flex-col"
            >
              <div className="flex items-center justify-between p-6 border-b border-foreground/5">
                <div className="flex items-center gap-2 font-bold text-lg">
                  <ListTree className="w-5 h-5 text-primary" />
                  Documentation
                </div>
                <button
                  onClick={close}
                  className="p-2 -mr-2 text-foreground/50 hover:text-foreground transition-colors"
                >
                  <X className="w-6 h-6" />
                </button>
              </div>

              <nav className="flex-1 overflow-y-auto p-6">
                <ul className="space-y-1 list-none p-0 m-0">
                  {tree.children.map((node) => (
                    <NavBranch
                      key={node.path}
                      node={node}
                      currentPath={normalizedCurrentPath}
                      depth={0}
                      onNavigate={close}
                    />
                  ))}
                </ul>
              </nav>

              <div className="p-6 border-t border-foreground/5 bg-foreground/2">
                <a
                  href="/docs/overview"
                  className="flex items-center justify-center w-full px-4 py-3 bg-primary text-white rounded-xl font-bold shadow-lg shadow-primary/20 hover:bg-primary/90 transition-all text-sm"
                >
                  Quick Start Guide
                </a>
              </div>
            </motion.div>
          </>
        )}
      </AnimatePresence>
    </>
  );
}
