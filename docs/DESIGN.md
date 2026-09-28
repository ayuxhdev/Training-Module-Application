# Design

## 1. Purpose

This document defines the visual and interaction direction for the Garden's Need Training Module Application.

The design goal is to create a professional internal business application that feels:

- clear
- premium
- calm
- trustworthy
- practical
- easy to use

The interface should support employees, managers, coordinators, trainers, supervisors, and administrators without unnecessary complexity.

Functionality and usability take priority over decoration.

## 2. Design Principles

The application should follow these principles:

### Clarity First

Users should be able to understand:

- where they are
- what they need to do
- what is complete
- what remains
- what actions are available

### Consistency

Similar actions should look and behave consistently across the application.

Examples:

- primary actions use the same visual treatment
- destructive actions use the same warning treatment
- forms use consistent spacing
- cards use consistent structure
- status labels use consistent styles

### Low Cognitive Load

The application should not overwhelm users with unnecessary information.

Pages should prioritize the most important task first.

### Business-Oriented

The visual system should feel appropriate for internal company software.

Avoid overly playful consumer-app styling.

### Responsive

Important workflows must remain usable on:

- desktop
- laptop
- tablet
- mobile

### Accessible

Design decisions should support:

- keyboard navigation
- readable contrast
- clear focus states
- form labels
- useful error messages
- understandable status indicators

## 3. Brand Direction

The intended Garden's Need visual identity uses:

- deep forest green
- ivory / white
- charcoal
- restrained brass accents

The visual tone should feel premium but controlled.

Avoid:

- excessive gradients
- excessive shadows
- neon colors
- overly rounded consumer-app styling
- decorative animations that distract from work
- visual clutter

## 4. Suggested Color System

Final production color values should be validated visually during the premium polish milestone.

A practical starting direction:

### Primary

Deep forest green.

Used for:

- primary navigation
- primary buttons
- active states
- important brand elements

### Background

Ivory or soft off-white.

Used for:

- application background
- large page surfaces
- calm separation from white cards

### Surface

White.

Used for:

- cards
- forms
- tables
- dialogs
- content containers

### Text

Charcoal.

Used for:

- primary text
- headings
- table content

### Accent

Restrained brass or muted gold.

Used sparingly for:

- premium highlights
- badges
- decorative separators
- selected brand details

Accent color should not become the main action color.

## 5. Semantic Colors

Semantic colors should communicate system meaning consistently.

### Success

Used for:

- completed training
- passing assessment
- successful actions
- active certificate

### Warning

Used for:

- due soon
- incomplete requirements
- caution states

### Danger

Used for:

- failed assessment
- overdue training
- destructive actions
- revocation
- serious validation problems

### Neutral

Used for:

- draft
- inactive
- secondary information
- optional metadata

Do not communicate important status using color alone.

Use text, icons, or labels as well.

## 6. Typography

Typography should prioritize readability.

Use a professional sans-serif typeface.

The final font should be:

- easy to read
- widely supported
- appropriate for dashboards
- clean at small sizes

Avoid using multiple competing font families.

A practical hierarchy:

```text
Page Title
Section Heading
Card Heading
Body Text
Secondary Text
Caption / Metadata
```

Font weight should be used sparingly.

Avoid making every heading bold.

## 7. Page Layout

The application should use a consistent shell.

Suggested structure:

```text
Top Bar / Header
|
+-- Sidebar or Main Navigation
|
+-- Main Content Area
    |
    +-- Page Header
    |
    +-- Primary Content
```

The exact navigation pattern should be finalized during frontend development.

## 8. Desktop Layout

Desktop pages should provide:

- clear navigation
- useful content width
- sufficient whitespace
- readable tables
- consistent page headers

Avoid stretching content across the full screen when a narrower content area improves readability.

## 9. Mobile Layout

Mobile layouts should:

- collapse navigation appropriately
- avoid horizontal scrolling where possible
- stack forms vertically
- convert wide tables where necessary
- keep important actions reachable
- maintain readable spacing

Critical employee workflows should work comfortably on smaller screens.

## 10. Navigation

Navigation should reflect the user's permissions.

Users should not see irrelevant sections.

However, hidden navigation is not a security control.

Backend authorization remains mandatory.

Possible navigation areas include:

```text
Dashboard
My Training
Training Management
Assignments
Assessments
Certificates
Reports
Organization
Audit
```

The exact navigation shown should depend on role and permissions.

## 11. Navigation States

Navigation should clearly indicate:

- current section
- expanded section
- selected page

Avoid ambiguous active states.

## 12. Page Headers

Each major page should have a consistent header containing:

- page title
- optional short description
- important primary action
- optional breadcrumb

Example:

```text
Training
Manage training programs and versions.

[Create Training]
```

## 13. Breadcrumbs

Breadcrumbs may be useful for deeply nested training content.

Example:

```text
Training
> Workplace Safety
> Version 2
> Module 1
> Lesson 3
```

Do not add breadcrumbs where they provide no useful context.

## 14. Cards

Cards should be used for:

- dashboard metrics
- training summaries
- certificate summaries
- employee training items
- grouped actions

Cards should have:

- consistent padding
- subtle borders
- limited shadow
- clear heading
- predictable structure

Avoid turning every piece of content into a card.

## 15. Dashboard Design

Dashboards should prioritize actionable information.

Examples:

### Administrator / Coordinator

Potential dashboard elements:

- active employees
- published training
- assignments
- overdue assignments
- completion rate
- recent activity

### Manager

Potential dashboard elements:

- employees in scope
- assigned training
- overdue training
- completion status

### Employee

Potential dashboard elements:

- assigned training
- training in progress
- due dates
- completed training
- certificates

Dashboards should not become overloaded analytics screens.

## 16. Metric Cards

Metric cards should display:

- clear label
- clear number
- optional supporting text

Example:

```text
Overdue Training
12
Employees requiring attention
```

Avoid excessive decorative icons or charts for simple metrics.

## 17. Tables

Tables will be important throughout the application.

Use tables for:

- employees
- assignments
- training
- certificates
- reports
- audit events

Tables should include:

- readable headers
- clear row spacing
- aligned data
- visible actions
- useful empty states

Avoid extremely dense spreadsheet-like styling.

## 18. Table Actions

Row actions should be consistent.

Examples:

```text
View
Edit
Assign
Revoke
Deactivate
```

Destructive actions should be visually distinct.

Do not make every row action a bright primary button.

## 19. Responsive Tables

Wide tables may not fit smaller screens.

Possible approaches:

- hide low-priority columns
- allow controlled horizontal scrolling
- convert rows to stacked cards
- provide mobile-specific summaries

The best solution should depend on the specific table.

## 20. Forms

Forms should be easy to scan.

Use:

- visible labels
- logical grouping
- useful help text
- consistent spacing
- clear validation

Avoid forms where labels exist only as placeholders.

## 21. Form Layout

Simple forms should usually use a single-column layout.

Two-column layouts may be used for short related fields on wide screens.

On mobile, forms should normally collapse to one column.

## 22. Form Validation

Validation messages should:

- explain the problem
- appear near the relevant field
- avoid technical jargon
- preserve user input where safe

Example:

Poor:

```text
Invalid value.
```

Better:

```text
Due date must be on or after the assignment date.
```

## 23. Required Fields

Required fields should be clearly indicated.

Do not rely only on color.

## 24. Buttons

Buttons should follow a hierarchy.

### Primary

Use for the main action on a page.

Examples:

```text
Save
Create Training
Publish
Submit Assessment
```

### Secondary

Use for less important actions.

Examples:

```text
Cancel
Back
Preview
```

### Destructive

Use for dangerous actions.

Examples:

```text
Deactivate
Revoke
Retire
```

Avoid multiple competing primary buttons on the same page.

## 25. Destructive Actions

Destructive or important irreversible actions should require deliberate confirmation when appropriate.

Examples:

- employee deactivation
- certificate revocation
- training retirement

Confirmation text should clearly state the consequence.

## 26. Status Badges

Use consistent badges for status values.

Examples:

```text
Draft
Published
Retired
Assigned
In Progress
Completed
Overdue
Passed
Failed
Active
Revoked
```

Badges should use both text and color.

## 27. Training Status

Training cards or rows should make progress easy to understand.

Possible states:

```text
Not Started
In Progress
Completed
Overdue
```

For employees, the next required action should be obvious.

## 28. Progress Indicators

Training progress may use:

- percentage
- progress bar
- completed lesson count

Progress should reflect trusted backend state.

The frontend should only display authoritative values from the backend.

## 29. Training Detail Page

A training detail page may include:

- title
- description
- due date
- progress
- module list
- lessons
- assessment status
- certificate state

The employee should understand the next step immediately.

## 30. Module Design

Modules should appear as clearly separated sections.

Example:

```text
Module 1
Introduction

✓ Lesson 1
▶ Lesson 2
○ Lesson 3
```

Icons should support text, not replace it.

## 31. Lesson Design

Lesson pages should provide:

- lesson title
- content
- progress context
- next/back navigation

Avoid unnecessary side content that distracts from learning.

## 32. Video Lesson Design

Video lesson pages should prioritize the video.

Potential layout:

```text
Lesson Title

[ Video Player ]

Progress / status

Previous Lesson       Next Lesson
```

The UI may show progress, but backend logic remains authoritative.

## 33. Video Player States

Useful player states may include:

- loading
- playing
- paused
- completed
- error

Errors should provide a useful next action where possible.

## 34. Assessment Design

Assessment pages should feel focused.

Avoid displaying unnecessary dashboard navigation inside an active assessment if it distracts users.

Assessment pages should include:

- assessment title
- instructions
- progress
- question
- answer options
- submit/next action

## 35. Assessment Results

Results should clearly show:

- pass/fail
- score
- next step

Do not expose correct answers unless the product explicitly allows it.

## 36. Certificate Design

Certificate pages should clearly show:

- employee
- training
- training version
- issue date
- certificate number
- status

Revoked certificates should remain visible but clearly marked as revoked where authorized.

## 37. Reports

Report interfaces should support:

- clear filters
- reset action
- readable results
- useful empty state
- current filter visibility

Filters should not become visually overwhelming.

## 38. Report Filters

Filters may include:

- status
- department
- job role
- training
- training version
- overdue

Desktop layouts may place filters horizontally or in a compact panel.

Mobile layouts should stack or collapse filters.

## 39. Audit Log Design

Audit pages should be information-dense but readable.

Columns may include:

```text
Time
Performed By
Action
Target
Details
```

Use the visible term:

```text
Performed By
```

rather than:

```text
Actor
```

The backend field may remain named `actor`.

## 40. Empty States

Every important list should have a useful empty state.

Examples:

```text
No training has been assigned yet.
```

```text
No certificates have been issued.
```

```text
No audit events match these filters.
```

Avoid showing a blank table without explanation.

## 41. Loading States

Where JavaScript introduces delayed operations, use clear loading feedback.

Examples:

- saving
- submitting assessment
- loading video
- filtering reports

Avoid unnecessary animated loaders for fast server-rendered pages.

## 42. Error States

Errors should be understandable.

Good error pages should explain:

- what happened
- whether the user can fix it
- what they should do next

Do not expose internal stack traces or technical details in production.

## 43. Success Messages

Use confirmation messages for important successful actions.

Examples:

```text
Training published successfully.
```

```text
Employee deactivated.
```

```text
Certificate revoked.
```

Messages should be concise.

## 44. Notifications

V1 may use standard page-level or toast-style messages for immediate action feedback.

A full notification center is future scope unless explicitly implemented.

## 45. Accessibility

Accessibility should be integrated into design.

Requirements include:

- semantic HTML
- keyboard access
- visible focus states
- labels
- sufficient contrast
- readable font sizes
- meaningful link text
- accessible buttons
- understandable error messages

## 46. Keyboard Navigation

Important workflows should be usable without a mouse.

Interactive controls must be reachable through normal keyboard navigation.

Do not remove browser focus outlines unless a clear accessible replacement is provided.

## 47. Focus States

Focus states should be visible and consistent.

Use a high-contrast focus ring appropriate to the brand.

## 48. Color Contrast

Text and interactive elements should maintain sufficient contrast.

Muted text must remain readable.

Brass accent colors should not be used for important low-contrast body text.

## 49. Icons

Icons may improve scanning but should not replace important text.

For example:

Good:

```text
✓ Completed
```

Risky:

```text
✓
```

with no text or accessible label.

## 50. Responsive Breakpoints

Exact breakpoints should be defined during implementation rather than guessed in documentation.

The design should adapt naturally across:

- large desktop
- standard laptop
- tablet
- mobile

Avoid creating excessive breakpoint-specific complexity.

## 51. Spacing System

Use a consistent spacing scale.

For example:

```text
4
8
12
16
24
32
48
```

The final implementation may use CSS variables.

Consistent spacing matters more than the exact numeric scale.

## 52. Border Radius

Use moderate border radius.

Avoid extremely rounded pill-shaped cards throughout the application.

Pills are appropriate for:

- status badges
- compact filters
- tags

Cards and forms should remain restrained.

## 53. Shadows

Use shadows sparingly.

Prefer:

- subtle borders
- slight elevation

over large decorative shadows.

## 54. CSS Architecture

The frontend should avoid unnecessary complexity.

A practical structure may include:

```text
static/
└── css/
    ├── base.css
    ├── layout.css
    ├── components.css
    └── pages/
```

The exact structure should reflect actual frontend needs.

Avoid creating dozens of tiny CSS files prematurely.

## 55. CSS Variables

Shared design values should eventually use CSS custom properties.

Example:

```css
:root {
    --color-primary: ...;
    --color-background: ...;
    --color-surface: ...;
    --color-text: ...;
    --color-accent: ...;
}
```

Final values should be chosen during implementation and visual polish.

## 56. Reusable Components

Reusable UI patterns may include:

- buttons
- badges
- cards
- tables
- form fields
- alerts
- page headers
- metric cards
- breadcrumbs
- progress bars
- empty states

Reuse should improve consistency without creating an unnecessary component framework.

## 57. Template Architecture

Django templates should use inheritance where appropriate.

Example:

```text
base.html
|
+-- dashboard.html
+-- training/
+-- assessments/
+-- certificates/
+-- reports/
```

Shared elements may include:

- navigation
- messages
- page shell
- footer
- reusable partials

## 58. JavaScript Strategy

JavaScript should remain lightweight.

Use JavaScript for interactions where it provides real value.

Examples:

- playback heartbeat
- dynamic form behavior
- confirmation interactions
- progressive enhancement

Avoid rebuilding the whole application in JavaScript.

## 59. Progressive Enhancement

Where practical, core workflows should remain understandable even if JavaScript fails.

JavaScript-dependent features should fail safely.

Security must never depend solely on JavaScript.

## 60. Animation

Animation should be minimal.

Appropriate examples:

- subtle menu transition
- modal appearance
- progress change

Avoid:

- decorative bouncing
- excessive motion
- animation on every card
- long transitions that slow work

Respect reduced-motion preferences where practical.

## 61. Employee Experience

Employee workflows should be especially simple.

The typical employee should not need to understand the full system architecture.

Primary employee questions are:

```text
What training do I need to complete?
What should I do next?
When is it due?
Did I pass?
Is my certificate available?
```

The UI should answer these quickly.

## 62. Manager Experience

Managers need visibility without administrative overload.

Primary Manager questions may include:

```text
Who reports to me?
Who has incomplete training?
Who is overdue?
What is the completion status of my team?
```

The interface should stay within the Manager's authorized scope.

## 63. Training Coordinator Experience

Training Coordinators need operational efficiency.

Important tasks may include:

- managing training
- publishing versions
- creating assignments
- managing assessments
- reviewing certificates
- reviewing reports
- viewing audit records

Frequent actions should require minimal unnecessary navigation.

## 64. Administrator Experience

Administrators may need broad access to:

- organization
- training
- permissions
- reports
- audits

The interface should expose advanced controls clearly without making ordinary pages feel cluttered.

## 65. Visual Hierarchy

Each page should have a clear hierarchy:

```text
Page title
Primary action
Important status
Main content
Secondary information
```

Do not make metadata visually compete with the page's main task.

## 66. Content Density

Administrative tables can be moderately dense.

Employee training pages should feel more spacious and instructional.

Use different density appropriately rather than forcing one layout style everywhere.

## 67. Content Language

Interface text should be:

- direct
- concise
- professional
- understandable

Avoid technical Django terminology in user-facing messages.

Example:

Poor:

```text
Object validation failed.
```

Better:

```text
This training cannot be published until a final assessment is configured.
```

## 68. Date and Time Display

Dates should use a consistent display format.

The final format should reflect business preference.

Internally, the backend remains responsible for authoritative timestamps.

## 69. Confirmation Dialogs

Confirmation should be reserved for actions with meaningful consequences.

Examples:

- revoke certificate
- deactivate employee
- retire training

Do not add confirmation dialogs to routine navigation or simple saves.

## 70. Search

Search may be added to areas where lists become large.

Potential areas:

- employees
- training
- certificates
- audit logs

Do not add search to every page automatically.

## 71. Pagination

Long tables should eventually support pagination where necessary.

Examples:

- employees
- audit logs
- reports
- certificates

Pagination behavior must preserve active filters.

## 72. Performance Perception

Even when server operations are fast, the UI should communicate clearly during slower actions.

Avoid allowing users to submit the same action repeatedly because no feedback appeared.

This is especially important for:

- assessment submission
- publishing
- assignments
- certificate actions

## 73. Duplicate Submission Protection

The frontend may disable a submit button after submission to reduce accidental double clicks.

This is only a usability improvement.

The backend must still handle duplicate or concurrent submissions safely.

## 74. Security and Design

Visual design must never imply that hidden UI controls provide authorization.

Example:

Hiding an "Audit" navigation item from an Employee is good UX.

But the `/audit/` backend route must still reject the Employee directly.

## 75. Design Milestones

Design work is intentionally staged.

### Milestone 12

Build the complete functional frontend.

Priority:

```text
Does it work?
```

### Milestone 13

Improve:

- usability
- responsive layout
- accessibility
- interaction quality

Priority:

```text
Is it easy to use?
```

### Milestone 18

Apply premium final visual polish.

Priority:

```text
Does it feel like a finished Garden's Need product?
```

This order prevents visual work from repeatedly being rebuilt while functionality changes.

## 76. Premium Visual Polish

The final visual pass may refine:

- typography
- exact color palette
- spacing
- navigation
- tables
- cards
- forms
- dashboards
- icons
- empty states
- interaction states

The final pass should avoid changing backend business logic.

## 77. Design Validation

The completed frontend should be tested through real workflows.

Visual review should include:

- desktop
- laptop
- tablet
- mobile

Representative roles should include:

- Administrator
- Training Coordinator
- Manager
- Employee

## 78. Browser Validation

Playwright and live browser testing should eventually verify:

- navigation
- responsive states
- forms
- role-specific pages
- complete training workflows

Screenshots may be useful for identifying visual regressions.

## 79. Accessibility Validation

Before release, verify important workflows for:

- keyboard use
- focus visibility
- form labels
- heading hierarchy
- contrast
- button semantics
- links
- error feedback

## 80. Design Non-Goals

For V1, avoid unnecessary work such as:

- complex animation systems
- custom design-system framework
- full SPA rewrite
- excessive charting
- decorative gamification
- public marketing-site styling inside the internal application

## 81. Current Design Status

Current status:

```text
Design direction: defined
Functional frontend: pending
Responsive/UX implementation: pending
Accessibility pass: pending
Premium visual polish: pending
```

The visual rules in this document are guidance for upcoming frontend milestones.

Exact CSS values, component dimensions, and final visual details should be established through implementation and browser testing rather than treated as fixed before the frontend exists.