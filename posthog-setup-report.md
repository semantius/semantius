<wizard-report>
# PostHog post-wizard report

The wizard has completed a deep integration of PostHog analytics into the Semantius.com Astro (static SSG) project. A new `PostHog.astro` component was created and added to the global `Layout.astro`. PostHog initializes after the user grants cookie consent (or immediately if they already have), following the same pattern as the existing `Analytics.astro`. Environment variables are stored in `apps/web/.env` and referenced via Astro's `import.meta.env`. Twelve events were instrumented across seven files covering the full conversion funnel: from hero CTAs and signup modal opens, through pricing plan selections, search usage, model downloads, and contact form submissions, plus engagement signals like cookie consent and announcement banner interactions.

| Event | Description | File |
|-------|-------------|------|
| `signup_modal_opened` | User opens the waitlist sign-up modal (via button click or #signup hash) | `apps/web/src/components/islands/SignUpModal.jsx` |
| `pricing_plan_cta_clicked` | User clicks the CTA button on a pricing plan card, linking to app sign-up | `apps/web/src/components/sections/PricingPlan.astro` |
| `contact_form_submitted` | User successfully submits the contact form | `apps/web/src/components/islands/ContactForm.jsx` |
| `search_opened` | User opens the search modal (via button or Cmd+K) | `apps/web/src/components/islands/Search.jsx` |
| `search_result_clicked` | User clicks a search result item | `apps/web/src/components/islands/Search.jsx` |
| `announcement_banner_cta_clicked` | User clicks the CTA link in the announcement banner | `apps/web/src/components/sections/AnnouncementBanner.astro` |
| `announcement_banner_dismissed` | User dismisses the announcement banner | `apps/web/src/components/sections/AnnouncementBanner.astro` |
| `model_download_clicked` | User clicks the Download button on a model detail page | `apps/web/src/pages/models/[slug]/index.astro` |
| `model_view_clicked` | User clicks the View Model button on a model detail page | `apps/web/src/pages/models/[slug]/index.astro` |
| `cookie_consent_accepted` | User accepts cookie consent | `apps/web/src/components/common/CookieConsent.astro` |
| `cookie_consent_declined` | User declines cookie consent | `apps/web/src/components/common/CookieConsent.astro` |
| `hero_cta_clicked` | User clicks a CTA button in the hero section (primary or secondary) | `apps/web/src/components/sections/Hero.astro` |

## Next steps

We've built some insights and a dashboard for you to keep an eye on user behavior, based on the events we just instrumented:

- **Dashboard — Analytics basics**: https://us.posthog.com/project/410767/dashboard/1546903
- **Signup funnel: Hero CTA → Modal → Contact submitted**: https://us.posthog.com/project/410767/insights/1VK2RJgp
- **Pricing plan CTA clicks by plan**: https://us.posthog.com/project/410767/insights/cswEACK6
- **Sign-up modal opens over time**: https://us.posthog.com/project/410767/insights/ie9xDzFn
- **Model downloads and views**: https://us.posthog.com/project/410767/insights/I7OSJ0v5
- **Cookie consent rate**: https://us.posthog.com/project/410767/insights/D7nGFEcG

### Agent skill

We've left an agent skill folder in your project. You can use this context for further agent development when using Claude Code. This will help ensure the model provides the most up-to-date approaches for integrating PostHog.

</wizard-report>
