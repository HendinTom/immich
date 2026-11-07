import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/features/gallery_review/review_swipe_card.dart';

void main() {
  var keeps = 0;
  var trashes = 0;

  Future<void> mount(WidgetTester tester, {bool enabled = true, bool trashEnabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 600,
              child: ReviewSwipeCard(
                enabled: enabled,
                trashEnabled: trashEnabled,
                onKeep: () => keeps++,
                onTrash: () => trashes++,
                child: const Center(child: Text('Synthetic photo')),
              ),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    keeps = 0;
    trashes = 0;
  });

  testWidgets('media moves while the edge feedback stays fixed', (tester) async {
    await mount(tester);
    final media = find.text('Synthetic photo');
    final originalCenter = tester.getCenter(media);
    final gesture = await tester.startGesture(originalCenter);
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    final labelPosition = tester.getTopLeft(find.text('KEEP →'));
    final firstMediaPosition = tester.getCenter(media);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(tester.getTopLeft(find.text('KEEP →')), labelPosition);
    expect(tester.getCenter(media).dx, greaterThan(firstMediaPosition.dx));
    expect(firstMediaPosition.dx, greaterThan(originalCenter.dx));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getCenter(media), originalCenter);
    expect(keeps, 0);
  });

  testWidgets('crossing the threshold then returning to center does not decide', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ReviewSwipeCard)));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    expect(keeps, 0); // Decisions happen on release, never during the drag.
    expect(find.text('KEEP →'), findsOneWidget);
    await gesture.moveBy(const Offset(-150, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(keeps, 0);
    expect(trashes, 0);
  });

  testWidgets('pointer cancellation does not trash after crossing the threshold', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ReviewSwipeCard)));
    await gesture.moveBy(const Offset(-30, 0));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump();
    expect(find.text('← TRASH'), findsOneWidget);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(trashes, 0);
    expect(keeps, 0);
  });

  testWidgets('release commits each direction once', (tester) async {
    await mount(tester);
    await tester.drag(find.byType(ReviewSwipeCard), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(keeps, 1);
    expect(trashes, 0);
    await tester.drag(find.byType(ReviewSwipeCard), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(keeps, 1);
    expect(trashes, 1);
  });

  testWidgets('disabled trash and busy state cannot trigger decisions', (tester) async {
    await mount(tester, trashEnabled: false);
    await tester.drag(find.byType(ReviewSwipeCard), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(trashes, 0);
    await mount(tester, enabled: false);
    await tester.drag(find.byType(ReviewSwipeCard), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(keeps, 0);
  });
}
