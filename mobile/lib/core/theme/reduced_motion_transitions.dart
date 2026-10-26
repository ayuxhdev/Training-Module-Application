import 'package:flutter/material.dart';

/// Preserve platform navigation, but bypass decorative travel for reduced motion.
/// Keep delegates mounted: they own edge-swipe and predictive-back handling.
class ReducedMotionTransitions extends PageTransitionsBuilder {
  final PageTransitionsBuilder delegate;
  const ReducedMotionTransitions({required this.delegate});

  @override
  Duration get transitionDuration => delegate.transitionDuration;

  @override
  Duration get reverseTransitionDuration => delegate.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition {
    final builder = delegate.delegatedTransition;
    if (builder == null) return null;
    return (context, animation, secondaryAnimation, allowSnapshotting, child) =>
        builder(
          context,
          MediaQuery.disableAnimationsOf(context)
              ? kAlwaysCompleteAnimation
              : animation,
          MediaQuery.disableAnimationsOf(context)
              ? kAlwaysDismissedAnimation
              : secondaryAnimation,
          allowSnapshotting,
          child,
        );
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => delegate.buildTransitions(
    route,
    context,
    // Freeze visual inputs, not the route controller used by back gestures.
    MediaQuery.disableAnimationsOf(context)
        ? kAlwaysCompleteAnimation
        : animation,
    MediaQuery.disableAnimationsOf(context)
        ? kAlwaysDismissedAnimation
        : secondaryAnimation,
    child,
  );
}
