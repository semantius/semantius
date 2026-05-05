import { useState, useEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { motion, AnimatePresence } from 'motion/react';

export default function SignUpModal({ triggerLabel = 'Sign up', waitlistKey = '' }) {
  const [isOpen, setIsOpen] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  const openModal = useCallback(() => {
    setIsOpen(true);
    if (window.location.hash !== '#signup') {
      window.history.replaceState(null, '', '#signup');
    }
    window.posthog?.capture('signup_modal_opened', { trigger: 'button' });
  }, []);

  const handleClose = useCallback(() => {
    setIsOpen(false);
    if (window.location.hash === '#signup') {
      window.history.replaceState(null, '', window.location.pathname + window.location.search);
    }
  }, []);

  // Open on #signup hash — works for deep links and hashchange navigation
  useEffect(() => {
    if (window.location.hash === '#signup') {
      setIsOpen(true);
      window.posthog?.capture('signup_modal_opened', { trigger: 'hash' });
    }
    const onHashChange = () => {
      if (window.location.hash === '#signup') {
        setIsOpen(true);
        window.posthog?.capture('signup_modal_opened', { trigger: 'hash' });
      }
    };
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  // Close on Escape key
  useEffect(() => {
    if (!isOpen) return;
    const onKeyDown = (e) => { if (e.key === 'Escape') handleClose(); };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [isOpen, handleClose]);

  const portal = (
    <AnimatePresence>
      {isOpen && (
        <>
          {/* Full-screen backdrop — click to close */}
          <motion.div
            key="backdrop"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={handleClose}
            aria-hidden="true"
            style={{
              position: 'fixed',
              inset: 0,
              backgroundColor: 'rgba(0,0,0,0.55)',
              backdropFilter: 'blur(4px)',
              zIndex: 9998,
            }}
          />

          {/* Flexbox centering wrapper */}
          <div
            key="wrapper"
            style={{
              position: 'fixed',
              inset: 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              zIndex: 9999,
              pointerEvents: 'none',
              padding: '1rem',
            }}
          >
            <motion.div
              role="dialog"
              aria-modal="true"
              aria-label="Sign up"
              initial={{ opacity: 0, scale: 0.95, y: 16 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 16 }}
              transition={{ type: 'spring', damping: 26, stiffness: 320 }}
              style={{
                pointerEvents: 'auto',
                maxHeight: 'calc(100dvh - 2rem)',
                overflowY: 'auto',
              }}
              className="w-full max-w-2xl bg-white dark:bg-background rounded-2xl shadow-2xl"
            >
              <div className="p-6">
                {/* embed.js (preloaded in <head>) watches document.body via MutationObserver
                    and injects its iframe as soon as this div appears in the DOM */}
                <div
                  className="waitlister-form"
                  data-waitlist-key={waitlistKey}
                  data-height="410px"
                />
              </div>
            </motion.div>
          </div>
        </>
      )}
    </AnimatePresence>
  );

  return (
    <>
      <button
        onClick={openModal}
        className="hidden md:block px-4 py-2 text-sm font-medium bg-primary text-white rounded-full hover:bg-primary/90 transition-all cursor-pointer"
      >
        {triggerLabel}
      </button>

      {mounted && createPortal(portal, document.body)}
    </>
  );
}
