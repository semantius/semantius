

export const siteConfig = {
  name: 'Semantius',
  description: 'Premium Astro Boilerplate for explorers.',
  logo: {
    src: '/semantius-logo.svg',
    srcDark: '/semantius-logo.svg',       // Used when strategy is 'switch'
    alt: 'Semantius Logo',
    strategy: 'static' as 'invert' | 'switch' | 'static', // 'invert' | 'switch' | 'static'
  },
  ogImage: '/og-image.webp',
  primaryColor: '#00008B', // Default primary color
  search: {
    enabled: true,
  },
  announcement: {
    enabled: true,
    id: 'public_beta_waitlist',
    link: '#signup',
    localizeLink: false,
  },
  blog: {
    postsPerPage: 6,
  },
  contact: {
    email: {
      support: 'support@interstellar.com',
      sales: 'sales@interstellar.com',
    },
    phone: {
      main: '+1 (555) 123-4567',
      label: 'Mon-Fri 9am-6pm PST'
    },
    address: {
      city: 'Endurance',
      full: 'Interstellar Space Station'
    }
  },
  analytics: {
    alwaysLoad: import.meta.env.ANALYTICS_ALWAYS_LOAD === 'true',
    vendors: {
      googleAnalytics: {
        id: import.meta.env.GA_ID || '',
        enabled: import.meta.env.GA_ENABLED === 'true',
      },
      rybbit: {
        id: import.meta.env.RYBBIT_ID || '',
        src: import.meta.env.RYBBIT_SRC || 'https://rybbit.example.com/api/script.js',
        enabled: import.meta.env.RYBBIT_ENABLED === 'true',
      },
      umami: {
        id: import.meta.env.UMAMI_ID || '',
        src: import.meta.env.UMAMI_SRC || 'https://analytics.umami.is/script.js',
        enabled: import.meta.env.UMAMI_ENABLED === 'true',
      },
    },
  },
  waitlister: {
    // Waitlister.me widget key — used to render the sign-up form in the modal.
    // Set WAITLISTER_KEY in your .env to enable it (data-waitlist-key value).
    waitlistKey: import.meta.env.WAITLISTER_KEY || '3-wGxQmqKCyY',
  },
  dateOptions: {
    localeMapping: {
      'ar': 'ar-TN', // Force Maghreb Arabic date format (e.g., جانفي instead of يناير)
      'en': 'en-GB', // Example: Force UK English date format
    }
  }
};

export const NAV_LINKS = [
  {
    href: '/features',
    label: 'Product',
    children: [
      { href: '/features', label: 'Features', description: 'What makes us different', icon: 'Zap' },
      { href: '/pricing', label: 'Pricing', description: 'Plans for every team', icon: 'CreditCard' },
    ]
  },
  {
    href: '/docs',
    label: 'Resources',
    children: [
      { href: '/skills', label: 'Skills', description: 'Agent skill library', icon: 'Wand2' },
      { href: '/models', label: 'Semantic Models', description: 'Semantic model library', icon: 'Database' },
      { href: '/docs/overview', label: 'Docs', description: 'Start building today', icon: 'Book', localize: false },
      { href: '/blog', label: 'Blog', description: 'Latest updates & guides', icon: 'Newspaper' },
      { href: '/changelog', label: 'Changelog', description: 'New features & fixes', icon: 'FileClock' },
    ]
  },
  // Company section temporarily hidden — restore when About/Contact pages are ready.
  // {
  //   href: '/about',
  //   label: 'Company',
  //   children: [
  //       { href: '/about', label: 'About', description: 'Our story & mission', icon: 'Building2' },
  //       { href: '/contact', label: 'Contact', description: 'Get in touch with us', icon: 'Mail' },
  //   ]
  // },
];

export const ACTION_LINKS = {
  primary: { label: 'Get Started', href: '/docs/overview' },
  signIn: { label: 'Sign in', href: 'https://app.semantius.com/' },
  social: {
    twitter: 'https://twitter.com/gladtek',
    linkedin: 'https://linkedin.com/company/gladtek',
    github: 'https://github.com/Semantius',
    youtube: 'https://youtube.com/@gladtek',
    facebook: 'https://facebook.com/gladtek'

  }
};

export const FOOTER_LINKS = {
  product: {
    title: 'Product',
    links: [
      { href: '/features', label: 'Features' },
      { href: '/about', label: 'About' },
      { href: '/pricing', label: 'Pricing' },
      { href: '/changelog', label: 'Changelog' },
    ],
  },
  legal: {
    title: 'Legal',
    links: [
      { href: '/privacy', label: 'Privacy', localize: false },
      { href: '/terms', label: 'Terms', localize: false }
    ],
  },
};
