# Design

## 1. Purpose

This document defines the visual, interaction, and usability direction for the Garden's Need Training Module Application.

The design goal is a professional internal business application that feels:

- clear
- premium
- calm
- trustworthy
- practical
- efficient
- easy to use

The application serves Employees, Managers, Training Coordinators, Trainers, Supervisors, and Administrators.

Functionality, usability, accessibility, and security take priority over decoration.

The final Garden's Need visual polish is intentionally scheduled for **M22**. Earlier milestones should establish a solid functional and usable interface without prematurely locking every visual detail.

---

# 2. Design Principles

## Clarity First

Users should quickly understand:

- where they are
- what they need to do
- what is complete
- what remains
- what is due
- what action is available next

## Consistency

Similar actions should look and behave consistently.

Examples:

- primary actions use consistent treatment
- destructive actions use consistent warning treatment
- forms use consistent spacing
- cards use consistent structure
- status labels use consistent styles
- navigation behaves consistently

## Low Cognitive Load

The application should not overwhelm users with unnecessary information.

Each page should prioritize the user's primary task.

## Business-Oriented

The interface should feel appropriate for internal enterprise software.

Avoid turning the product into a consumer social app or a marketing website.

## Responsive

Important workflows should remain usable across:

- desktop
- laptop
- tablet
- Android mobile

## Accessible

Design should support:

- keyboard navigation
- readable contrast
- visible focus states
- semantic structure
- clear labels
- understandable errors
- meaningful status indicators

---

# 3. Current Design State

The project currently has two active product surfaces:

```text
Django Web Application
        +
Flutter Android Employee Application
```

M14 established the Android application's foundation.

M15 established the employee learning flow.

The current mobile UI is therefore functional foundation work, not the final visual design.

The final visual system should not be considered locked until the dedicated polish phase.

---

# 4. Garden's Need Visual Direction

The intended visual direction is:

- premium
- restrained
- natural
- professional
- calm

A possible brand direction includes:

- deep forest green
- ivory / soft white
- charcoal
- restrained brass or muted gold

However, these are **design directions rather than immutable production values**.

Exact colors, typography, spacing, shadows, radii, and animation should be validated visually during M22.

Avoid:

- excessive gradients
- neon colors
- excessive shadows
- overly rounded consumer-app styling
- excessive glassmorphism
- decorative clutter
- unnecessary animation

---

# 5. Color System

The final production palette will be selected during M22.

A useful starting direction is:

## Primary

Deep forest green.

Potential uses:

- primary actions
- navigation
- active states
- important brand elements

## Background

Ivory or soft off-white.

Potential uses:

- application background
- page surfaces
- large content areas

## Surface

White.

Potential uses:

- cards
- forms
- tables
- dialogs
- content containers

## Text

Charcoal.

Potential uses:

- headings
- primary body text
- table content

## Accent

Restrained brass or muted gold.

Potential uses:

- premium highlights
- subtle decorative details
- selected brand elements

Accent colors should not become the dominant action color.

---

# 6. Semantic Colors

Semantic colors must communicate meaning consistently.

## Success

Examples:

- completed training
- passed assessment
- successful action
- active certificate

## Warning

Examples:

- due soon
- incomplete requirements
- caution states

## Danger

Examples:

- failed assessment
- overdue training
- destructive actions
- certificate revocation
- serious validation problems

## Neutral

Examples:

- draft
- inactive
- secondary information
- optional metadata

Important status must never be communicated through color alone.

Use text, icons, or labels as well.

---

# 7. Typography

Typography should prioritize readability.

The final font choice should be:

- professional
- readable
- broadly supported
- suitable for dashboards
- clear at small sizes

Avoid unnecessary font-family combinations.

A basic hierarchy is:

```text
Page Title
Section Heading
Card Heading
Body Text
Secondary Text
Caption / Metadata
```

Font weight should create hierarchy without making every heading heavy.

The final typography system will be validated during M22.

---

# 8. Web Application Layout

The Django application should use a consistent shell.

A possible structure is:

```text
Header
│
├── Navigation
│
└── Main Content
    │
    ├── Page Header
    │
    └── Primary Content
```

The exact navigation pattern should follow the existing Django implementation and be refined during later UX work.

---

# 9. Android Application Layout

The Flutter Android application should use a mobile-first structure appropriate for employee workflows.

Typical flow:

```text
App Shell
│
├── Dashboard
├── My Training
├── Training Detail
├── Module
├── Lesson
├── Assessment
└── Certificates
```

M14 and M15 establish the functional foundation.

M16 onward will add secure video and additional learning functionality.

The final visual system remains open until M22.

---

# 10. Desktop Layout

Desktop pages should provide:

- clear navigation
- useful content width
- sufficient whitespace
- readable tables
- consistent page headers
- clear primary actions

Avoid unnecessarily stretching content across the entire screen.

---

# 11. Mobile Layout

Mobile interfaces should:

- keep important actions reachable
- use readable spacing
- stack forms appropriately
- avoid unnecessary horizontal scrolling
- simplify dense information
- provide clear navigation
- preserve the user's current task

Critical Employee workflows should work comfortably on Android devices.

---

# 12. Navigation

Navigation should reflect the user's permissions.

Possible areas include:

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

The exact navigation depends on the authenticated role.

Hidden navigation is only a UX decision.

Backend authorization remains mandatory.

---

# 13. Navigation States

Navigation should clearly indicate:

- current section
- current page
- expanded section where applicable
- selected item

Active states should be visually obvious without relying solely on color.

---

# 14. Page Headers

Major pages should have a consistent header containing:

- page title
- optional description
- primary action where applicable
- optional breadcrumb

Example:

```text
Training
Manage training programs and versions.

[Create Training]
```

---

# 15. Breadcrumbs

Breadcrumbs are useful for deeply nested web content.

Example:

```text
Training
> Workplace Safety
> Version 2
> Module 1
> Lesson 3
```

Do not add breadcrumbs where they provide no useful navigation value.

Mobile interfaces should generally avoid unnecessary breadcrumb complexity.

---

# 16. Cards

Cards may be used for:

- dashboard metrics
- training summaries
- certificate summaries
- employee training items
- grouped actions

Cards should have:

- consistent padding
- restrained borders
- limited elevation
- clear headings
- predictable structure

Do not turn every piece of content into a card.

---

# 17. Dashboard Design

Dashboards should prioritize actionable information.

## Administrator / Coordinator

Potential information:

- active employees
- published training
- assignments
- overdue assignments
- completion
- recent activity

## Manager

Potential information:

- employees in scope
- assigned training
- overdue training
- completion status

## Employee

Potential information:

- assigned training
- training in progress
- due dates
- completed training
- certificates

Dashboards should not become unnecessarily dense analytics screens.

---

# 18. Metric Cards

Metric cards should communicate:

- clear label
- clear value
- optional supporting context

Example:

```text
Overdue Training
12
Employees requiring attention
```

Avoid excessive decorative charts or icons for simple metrics.

---

# 19. Tables

Tables are appropriate for administrative and reporting workflows.

Examples:

- employees
- assignments
- training
- certificates
- reports
- audit events

Tables should have:

- readable headers
- clear row spacing
- aligned information
- visible actions
- useful empty states

Avoid unnecessarily dense spreadsheet-style layouts.

---

# 20. Responsive Tables

On smaller screens, possible approaches include:

- hiding low-priority columns
- controlled horizontal scrolling
- stacked row summaries
- mobile-specific layouts

The appropriate solution depends on the table.

Do not force one responsive pattern onto every table.

---

# 21. Forms

Forms should be easy to scan.

Use:

- visible labels
- logical grouping
- useful help text
- consistent spacing
- clear validation
- accessible controls

Do not use placeholders as the only field labels.

---

# 22. Form Validation

Validation messages should:

- explain the problem
- appear near the relevant field
- avoid unnecessary technical terminology
- preserve user input where safe

Poor:

```text
Invalid value.
```

Better:

```text
Due date must be on or after the assignment date.
```

---

# 23. Buttons

Buttons should have a clear hierarchy.

## Primary

Examples:

```text
Save
Create Training
Publish
Submit Assessment
```

## Secondary

Examples:

```text
Cancel
Back
Preview
```

## Destructive

Examples:

```text
Deactivate
Revoke
Retire
```

Avoid multiple competing primary actions on one page.

---

# 24. Destructive Actions

Actions with meaningful consequences should require deliberate confirmation where appropriate.

Examples:

- employee deactivation
- certificate revocation
- training retirement

Confirmation should clearly communicate the consequence.

---

# 25. Status Badges

Use consistent status treatments.

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

Badges should communicate meaning through text as well as visual styling.

---

# 26. Training Status

Training interfaces should make the employee's current state obvious.

Possible states:

```text
Not Started
In Progress
Completed
Overdue
```

The next required action should be easy to identify.

---

# 27. Progress Indicators

Progress may be represented through:

- percentage
- progress bar
- completed lesson count

Progress displayed by the client must represent backend-authoritative state.

The frontend must not invent completion percentages or completion status.

---

# 28. Training Detail

A training detail screen may contain:

- title
- description
- due date
- progress
- module list
- lesson list
- assessment status
- certificate state

The employee should immediately understand what to do next.

---

# 29. Module Design

Modules should be visually separated.

Example:

```text
Module 1
Introduction

✓ Lesson 1
▶ Lesson 2
○ Lesson 3
```

Icons support the text but do not replace it.

---

# 30. Lesson Design

Lesson pages should prioritize:

- lesson title
- learning content
- progress context
- previous/next navigation
- completion state

Avoid unnecessary information competing with the lesson itself.

---

# 31. Text Lesson Design

Text lessons should provide a focused reading experience.

The completion action should be clear without overwhelming the content.

Completion remains backend-authoritative.

---

# 32. Video Lesson Design

Video lessons should prioritize the player.

A possible layout:

```text
Lesson Title

[ Video Player ]

Progress / Status

Previous Lesson        Next Lesson
```

The player UI may display progress, but authoritative progress and completion remain server-side.

M16 will establish the secure playback experience.

---

# 33. Video Player States

The video interface should handle:

- loading
- playing
- paused
- seeking
- completed
- playback error
- session error
- network interruption

Errors should provide an understandable next action where possible.

The client must not bypass server playback rules when recovering from errors.

---

# 34. Assessment Design

Assessment pages should feel focused.

A typical structure:

```text
Assessment Title

Instructions

Question 1 of N

Question

Answer Options

[Next]
```

Avoid unnecessary dashboard content while an employee is actively completing an assessment.

Assessment functionality is planned for M17 on Android.

---

# 35. Assessment Results

Results should clearly communicate:

- pass/fail
- score where appropriate
- next step
- retry state where applicable

Correct answers should not be exposed unless explicitly supported by product requirements.

---

# 36. Certificate Design

Certificate screens should clearly show:

- employee
- training
- training version
- issue date
- certificate number
- certificate status

Revoked certificates should remain visible where authorized and clearly indicate their revoked state.

---

# 37. Reports

Reports should provide:

- clear filters
- visible active filters
- reset action
- readable results
- useful empty states

Do not overwhelm users with unnecessary filtering controls.

---

# 38. Audit Log Design

Audit interfaces should be information-dense but readable.

Possible columns:

```text
Time
Performed By
Action
Target
Details
```

Use user-friendly language such as `Performed By` rather than exposing internal terminology such as `Actor`.

The backend model may continue using the field name `actor`.

---

# 39. Empty States

Important lists should provide useful empty states.

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

Avoid blank screens that give no explanation.

---

# 40. Loading States

Loading feedback should be used for operations that may take noticeable time.

Examples:

- saving
- submitting
- loading video
- filtering
- network requests

Avoid unnecessary loaders for operations that complete immediately.

---

# 41. Error States

Errors should explain:

- what happened
- whether the user can fix it
- what to do next

Production interfaces must not expose stack traces or internal implementation details.

---

# 42. Success Feedback

Important successful operations should provide concise feedback.

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

Feedback should not interrupt the workflow unnecessarily.

---

# 43. Notifications

Immediate action feedback may use:

- inline messages
- banners
- toast-style messages

A full notification center belongs to M18 or later unless explicitly required earlier.

---

# 44. Accessibility

Accessibility is part of the design rather than a final cosmetic pass.

Important requirements include:

- semantic HTML
- keyboard navigation
- visible focus
- accessible labels
- sufficient contrast
- readable text
- meaningful links
- accessible buttons
- understandable errors

Flutter controls should also provide appropriate semantics and touch targets.

---

# 45. Keyboard Navigation

Important web workflows should work without a mouse.

Interactive controls must be reachable through normal keyboard navigation.

Do not remove browser focus indicators without providing an accessible replacement.

---

# 46. Focus States

Focus indicators should be:

- visible
- consistent
- high enough contrast
- visually appropriate to the final brand palette

---

# 47. Color Contrast

Text and interactive elements must maintain sufficient contrast.

Muted text must remain readable.

Brass or gold accents should not be used as low-contrast body text.

---

# 48. Icons

Icons may improve scanning but should not replace important labels.

Good:

```text
✓ Completed
```

Risky:

```text
✓
```

with no accessible label or supporting text.

---

# 49. Touch Targets

Android controls should have comfortable touch targets.

Primary actions should not require precise tapping.

Dense administrative interfaces may use tighter layouts than Employee learning screens, but usability should remain the priority.

---

# 50. Responsive Breakpoints

Exact breakpoints should be established during implementation and browser/device testing.

The system should adapt naturally across:

- large desktop
- laptop
- tablet
- Android mobile

Avoid excessive breakpoint-specific overrides.

---

# 51. Spacing System

Use a consistent spacing scale.

A possible starting scale:

```text
4
8
12
16
24
32
48
```

The exact values may change during M22.

Consistency is more important than any individual number.

---

# 52. Border Radius

Use restrained border radius.

Avoid making the entire application consist of large rounded containers.

Pill-shaped elements are appropriate for:

- status badges
- compact filters
- tags

---

# 53. Shadows

Use elevation sparingly.

Prefer:

- subtle borders
- modest elevation
- clear hierarchy

over large decorative shadows.

---

# 54. CSS Architecture

The web application should avoid unnecessary frontend complexity.

A possible structure is:

```text
static/
└── css/
    ├── base.css
    ├── layout.css
    ├── components.css
    └── pages/
```

The actual structure should follow the needs of the existing application.

Do not create a large CSS architecture merely for theoretical reuse.

---

# 55. CSS Variables

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

Final values should be selected during the visual-polish phase.

---

# 56. Flutter Styling

The Flutter application should centralize shared visual decisions where practical.

Potential shared areas include:

- typography
- spacing
- button styles
- input styles
- cards
- status indicators
- colors
- navigation
- app-bar behavior

Avoid creating a large custom design system before the final visual direction has been approved.

---

# 57. Reusable Components

Useful reusable patterns include:

- buttons
- badges
- cards
- tables
- forms
- alerts
- page headers
- metric cards
- progress indicators
- empty states
- loading states
- error states

Reuse should improve consistency without creating unnecessary abstraction.

---

# 58. Django Template Architecture

Django templates should use inheritance where appropriate.

Example:

```text
base.html
│
├── dashboard.html
├── training/
├── assessments/
├── certificates/
└── reports/
```

Shared elements may include:

- navigation
- messages
- page shell
- footer
- reusable partials

---

# 59. JavaScript Strategy

JavaScript should remain focused and lightweight.

Appropriate uses include:

- video playback behavior
- heartbeat handling
- dynamic form behavior
- confirmation interactions
- progressive enhancement

Avoid rebuilding the Django application as a JavaScript SPA.

---

# 60. Mobile State Handling

Flutter may maintain local UI state for responsiveness.

However, local state must not become authoritative for:

- authorization
- assignment ownership
- progress
- completion
- assessment scores
- certificates

Server state remains authoritative.

---

# 61. Progressive Enhancement

Where practical, core web workflows should remain understandable if JavaScript is unavailable.

JavaScript-dependent features should fail safely.

Security must never depend on JavaScript.

---

# 62. Animation

Animation should support understanding rather than compete with the task.

Appropriate examples:

- subtle navigation transitions
- modal appearance
- progress transitions
- lightweight state changes

Avoid:

- decorative motion everywhere
- excessive bouncing
- long transitions
- animation on every card
- motion that slows work

Respect reduced-motion preferences where practical.

The final animation language will be decided during M22.

---

# 63. Employee Experience

Employee workflows should be the simplest part of the system.

Employees should quickly answer:

```text
What training do I need?
What should I do next?
When is it due?
Did I pass?
Is my certificate available?
```

The mobile application should prioritize these questions.

---

# 64. Manager Experience

Managers need useful visibility without administrative overload.

Typical questions:

```text
Who reports to me?
Who has incomplete training?
Who is overdue?
What is my team's completion status?
```

All Manager information must remain within authorized scope.

---

# 65. Training Coordinator Experience

Training Coordinators need efficient operational workflows.

Important tasks include:

- managing training
- publishing versions
- assigning training
- managing assessments
- reviewing certificates
- reviewing reports
- reviewing audit information

Frequent operations should require minimal unnecessary navigation.

---

# 66. Administrator Experience

Administrators may need access to:

- organization
- training
- permissions
- reports
- audits
- operational configuration

Advanced functionality should remain discoverable without cluttering ordinary workflows.

---

# 67. Visual Hierarchy

Each page should generally follow:

```text
Page Title
    ↓
Primary Action / Important Status
    ↓
Main Content
    ↓
Secondary Information
```

Metadata should not compete with the primary task.

---

# 68. Content Density

Administrative tables may be moderately dense.

Employee learning interfaces should generally be more spacious and instructional.

Different workflows may therefore use different density levels.

---

# 69. Content Language

User-facing language should be:

- direct
- concise
- professional
- understandable

Avoid technical implementation terminology.

Poor:

```text
Object validation failed.
```

Better:

```text
This training cannot be published until a final assessment is configured.
```

---

# 70. Date and Time

Dates and times should use a consistent user-facing format.

The final display format should follow business requirements.

Backend timestamps remain authoritative.

---

# 71. Confirmation Dialogs

Confirmation should be reserved for meaningful consequences.

Examples:

- retire training
- deactivate employee
- revoke certificate

Do not add confirmation to routine navigation or harmless saves.

---

# 72. Search

Search may be introduced where lists become large.

Potential areas:

- employees
- training
- certificates
- audit records

Do not automatically add search to every screen.

---

# 73. Pagination

Long datasets should support pagination where appropriate.

Examples:

- employees
- audit records
- certificates
- reports

Pagination should preserve active filters and sorting.

---

# 74. Performance Perception

The interface should communicate clearly during slower operations.

This is particularly important for:

- assessment submission
- publishing
- assignments
- certificate actions
- video startup
- network operations

Users should not be able to accidentally submit the same action repeatedly simply because feedback was delayed.

---

# 75. Duplicate Submission Protection

The frontend may disable a submit control while an operation is pending.

This is a usability feature only.

The backend must remain responsible for safely handling duplicate and concurrent requests.

---

# 76. Security and Design

Visual design must never be mistaken for authorization.

For example:

Hiding the Audit navigation item from an Employee is good UX.

It is not security.

The backend must still reject unauthorized requests to the audit endpoint.

The same principle applies to:

- reports
- assignments
- certificates
- training management
- organization management
- protected media

---

# 77. Design Milestones

Design work is intentionally staged with the broader roadmap.

## M14

Establish the Android foundation.

Priority:

```text
Does the application work?
```

## M15

Establish the core Employee learning experience.

Priority:

```text
Can the employee complete the basic learning flow?
```

## M16

Add secure video learning.

Priority:

```text
Can the employee securely consume video training?
```

## M17

Add assessment and certificate experiences.

Priority:

```text
Can the employee complete and understand the full training outcome?
```

## M18

Improve resilience and operational feedback.

Priority:

```text
Does the application behave predictably under normal failures?
```

## M19

Prepare the Android release candidate.

Priority:

```text
Is the Android product stable enough for final release testing?
```

## M20

Harden production and deployment.

Priority:

```text
Can the system be operated safely?
```

## M21

Perform the final bug, security, and repository review.

Priority:

```text
Is the product technically ready for release?
```

## M22

Perform readability, refactoring, and final Garden's Need visual polish.

Priority:

```text
Does the finished product look and feel like a polished Garden's Need application?
```

## M23

Perform final acceptance and Android V1 release.

Priority:

```text
Is the product ready for real employees?
```

---

# 78. Premium Visual Polish

The M22 visual pass may refine:

- exact color palette
- typography
- spacing
- navigation
- dashboards
- cards
- tables
- forms
- icons
- empty states
- loading states
- error states
- progress indicators
- mobile layouts
- animation
- interaction states

The purpose is to make the product feel cohesive and premium without sacrificing usability.

Visual polish should not introduce unrelated backend changes.

---

# 79. Design Validation

Design should be validated through actual workflows rather than static mockups alone.

Validation should cover:

- desktop
- laptop
- tablet
- Android phone

Representative roles:

- Administrator
- Training Coordinator
- Manager
- Employee

Employee flows deserve particular attention because the Android application is the V1 mobile product.

---

# 80. Browser and Device Validation

Where appropriate, live browser and device testing should verify:

- navigation
- responsive states
- forms
- role-specific pages
- training workflows
- playback
- assessments
- certificates

Visual screenshots may be used during review to identify regressions.

Android validation should use real devices before release.

---

# 81. Accessibility Validation

Before release, verify important workflows for:

- keyboard access
- visible focus
- form labels
- heading hierarchy
- contrast
- button semantics
- link semantics
- error feedback
- touch-target usability
- reduced-motion behavior where applicable

---

# 82. Design Non-Goals

V1 does not require:

- a custom frontend framework
- a full SPA rewrite
- complex animation infrastructure
- excessive charting
- decorative gamification
- a public marketing-site visual language
- a large custom design-system package
- unnecessary component abstraction

The objective is a polished internal product, not visual complexity for its own sake.

---

# 83. Current Design Status

```text
Design direction:              Defined
Django functional UI:          Existing
Flutter foundation:            Complete
Employee learning UI:          Functional
Secure video UI:               M16
Assessment UI:                 M17
Resilience UX:                 M18
Android release-candidate UI:  M19
Final visual polish:           M22
Final acceptance:              M23
```

The exact visual system is intentionally not frozen yet.

The current priority is to complete the functional product safely, then use M22 as the deliberate visual-design phase for the final Garden's Need experience.