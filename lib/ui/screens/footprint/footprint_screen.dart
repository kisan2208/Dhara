import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../core/utils/tree_co2.dart';
import '../../../data/models/footprint.dart';
import '../../../state/footprint_controller.dart';
import '../../../state/trees_controller.dart';
import '../../widgets/common.dart';
import '../../widgets/footprint_widgets.dart';
import 'methodology_screen.dart';

/// The months a footprint can be filed under, newest first.
///
/// Counted from the current UTC month, because that is what the server checks
/// a month against. Using the phone's local date offered a month the server
/// rejected for the first five and a half hours of every month in India.
List<String> recentMonthKeys({DateTime? now, int count = 12}) {
  final n = now ?? DateTime.now().toUtc();
  return [
    for (var i = 0; i < count; i++)
      DateFormat('yyyy-MM').format(DateTime.utc(n.year, n.month - i, 1)),
  ];
}

String monthLabel(String key) {
  final p = key.split('-');
  final y = p.length == 2 ? int.tryParse(p[0]) : null;
  final m = p.length == 2 ? int.tryParse(p[1]) : null;
  return (y == null || m == null)
      ? key
      : DateFormat('MMMM yyyy').format(DateTime(y, m));
}

/// Allows digits with an optional decimal part and nothing else: at most six
/// whole digits and two decimals, which covers every limit the server sets.
class DecimalFormatter extends TextInputFormatter {
  const DecimalFormatter();

  static final _valid = RegExp(r'^\d{0,6}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue next) =>
      _valid.hasMatch(next.text) ? next : old;
}

/// Works out a monthly carbon footprint from home energy and travel.
///
/// The app does no emissions maths: it sends what the person typed and shows
/// what the server returns, so there is one implementation of the calculation
/// and one list of sources.
class FootprintScreen extends ConsumerStatefulWidget {
  const FootprintScreen({super.key});

  static Future<void> push(BuildContext context) {
    Haptics.tap();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const FootprintScreen()),
    );
  }

  @override
  ConsumerState<FootprintScreen> createState() => _FootprintScreenState();
}

class _FootprintScreenState extends ConsumerState<FootprintScreen> {
  final _kwh = TextEditingController();
  final _lpg = TextEditingController();
  final _travel = {for (final m in kTravelModes) m.key: TextEditingController()};

  late final List<String> _months = recentMonthKeys();
  late String _month = _months.first;

  int _household = 1;
  int _occupants = 1;

  FootprintResult? _result;

  /// What the result was worked out from, so edits made afterwards are noticed.
  String? _resultFor;

  bool _busy = false;
  String? _error;
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_kwh, _lpg, ..._travel.values]) {
      c.addListener(_onEdit);
    }
    ref.listenManual(footprintHistoryProvider, (_, next) {
      // Fill the form from the saved month once, as soon as history arrives.
      if (!_prefilled && next.hasValue) {
        _prefilled = true;
        _load(_entryFor(_month, next.value!));
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    for (final c in [_kwh, _lpg, ..._travel.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onEdit() => setState(() {});

  FootprintEntry? _entryFor(String month, List<FootprintEntry> all) {
    for (final e in all) {
      if (e.monthKey == month) return e;
    }
    return null;
  }

  static double _num(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0;

  static String _show(double v) => v == 0
      ? ''
      : (v == v.roundToDouble() ? v.round().toString() : v.toString());

  FootprintInputs _inputs() => FootprintInputs(
        householdSize: _household,
        carOccupants: _occupants,
        electricityKwh: _num(_kwh),
        lpgCylinders: _num(_lpg),
        travel: {for (final e in _travel.entries) e.key: _num(e.value)},
      );

  String _signature() => jsonEncode(_inputs().toJson());

  /// Replaces the form with a saved month, or empties it.
  void _load(FootprintEntry? entry) {
    final i = entry?.inputs;
    setState(() {
      _household = i?.householdSize ?? _household;
      _occupants = i?.carOccupants ?? 1;
      _kwh.text = _show(i?.electricityKwh ?? 0);
      _lpg.text = _show(i?.lpgCylinders ?? 0);
      for (final m in kTravelModes) {
        _travel[m.key]!.text = _show(i?.travel[m.key] ?? 0);
      }
      _result = null;
      _resultFor = null;
      _error = null;
    });
  }

  Future<void> _run(Future<FootprintResult> Function() work, {String? done}) async {
    if (_busy) return;
    final signature = _signature();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await work();
      if (!mounted) return;
      Haptics.success();
      setState(() {
        _result = result;
        _resultFor = signature;
      });
      if (done != null) showSnack(context, done);
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _error = friendlyMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _calculate() =>
      _run(() => ref.read(footprintServiceProvider).estimate(_inputs()));

  Future<void> _save() => _run(
        () async {
          final saved =
              await ref.read(footprintServiceProvider).save(_inputs(), _month);
          ref.invalidate(footprintHistoryProvider);
          return saved;
        },
        done: 'Saved for ${monthLabel(_month)}.',
      );

  Future<void> _delete(FootprintEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${entry.label}?'),
        content: const Text(
          'This removes that month from your history. You can enter it again '
          'any time.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(footprintServiceProvider).delete(entry.monthKey);
      ref.invalidate(footprintHistoryProvider);
      if (mounted) showSnack(context, '${entry.label} deleted.');
    } catch (e) {
      if (mounted) showSnack(context, friendlyMessage(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(footprintHistoryProvider);
    final saved = history.value ?? const <FootprintEntry>[];
    final inputs = _inputs();
    final stale = _result != null && _resultFor != _signature();
    final isSaved = _entryFor(_month, saved) != null;
    final usesCar = (_num(_travel['car_petrol']!) + _num(_travel['car_diesel']!)) > 0;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Carbon footprint')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            const Text(
              'Work out the CO\u2082 from your home energy and travel. It takes '
              'a minute, and you can leave anything blank.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: AppColors.inkSoft,
              ),
            ),
            TextButton(
              onPressed: () => MethodologyScreen.push(context),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
                minimumSize: const Size(0, 36),
              ),
              child: const Text('How we calculate this'),
            ),
            const SizedBox(height: 8),

            DropdownButtonFormField<String>(
              initialValue: _month,
              decoration: const InputDecoration(
                labelText: 'Month',
                prefixIcon: Icon(Icons.calendar_month_rounded),
              ),
              items: [
                for (final m in _months)
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      _entryFor(m, saved) == null
                          ? monthLabel(m)
                          : '${monthLabel(m)}  \u00B7  saved',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (m) {
                      if (m == null || m == _month) return;
                      setState(() => _month = m);
                      _load(_entryFor(m, saved));
                    },
            ),

            const _Heading('Your household'),
            _Stepper(
              label: 'People in your household',
              hint: 'Home electricity and gas are shared between them.',
              value: _household,
              min: 1,
              max: 20,
              onChanged: (v) => setState(() => _household = v),
            ),

            const _Heading('At home, this month'),
            _Field(
              controller: _kwh,
              label: 'Electricity used',
              suffix: 'kWh',
              hint: 'On your bill this is "units consumed". One unit is one kWh.',
              icon: Icons.bolt_rounded,
            ),
            _Field(
              controller: _lpg,
              label: 'Cooking gas',
              suffix: 'cylinders',
              hint: 'Enter 1 for a month\'s cylinder, or 0.5 if one lasts two months.',
              icon: Icons.local_fire_department_rounded,
            ),

            const _Heading('Getting about, this month'),
            for (final m in kTravelModes)
              _Field(
                controller: _travel[m.key]!,
                label: m.label,
                suffix: 'km',
                hint: m.unit,
                icon: _modeIcon(m.key),
              ),
            if (usesCar)
              _Stepper(
                label: 'People usually in the car',
                hint: 'A shared car splits its emissions between everyone in it.',
                value: _occupants,
                min: 1,
                max: 8,
                onChanged: (v) => setState(() => _occupants = v),
              ),

            const SizedBox(height: 18),
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _busy || !inputs.hasActivity ? null : _calculate,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : const Icon(Icons.calculate_rounded, size: 19),
              label: Text(_busy ? 'Working\u2026' : 'Work it out'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            if (!inputs.hasActivity)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Enter at least one thing above to continue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.inkFaint),
                ),
              ),

            if (_result != null) ...[
              const SizedBox(height: 22),
              if (stale)
                const _StaleNote()
              else ...[
                _ResultCard(result: _result!),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: Icon(isSaved ? Icons.sync_rounded : Icons.bookmark_add_outlined, size: 18),
                  label: Text(isSaved
                      ? 'Update ${monthLabel(_month)}'
                      : 'Save for ${monthLabel(_month)}'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Saving keeps it in your history. Only you can see it, and it '
                  'never changes your credits.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w500, color: AppColors.inkFaint),
                ),
              ],
            ],

            if (saved.isNotEmpty) ...[
              const _Heading('Your history'),
              if (saved.length >= 2)
                DharaCard(
                  padding: const EdgeInsets.fromLTRB(10, 16, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 6, bottom: 10),
                        child: Text(
                          'kg CO\u2082e a month',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.inkFaint),
                        ),
                      ),
                      FootprintHistoryChart(entries: saved),
                    ],
                  ),
                ),
              if (saved.length >= 2) const SizedBox(height: 12),
              for (final e in saved)
                _HistoryRow(
                  entry: e,
                  onOpen: () {
                    // Only months that can still be filed open into the form.
                    // An older one used to load its numbers under whichever
                    // month was selected, and "Update" then overwrote that
                    // month with them.
                    if (!_months.contains(e.monthKey)) {
                      showSnack(
                        context,
                        '${monthLabel(e.monthKey)} is too old to edit. '
                        'Only the last ${_months.length} months can be changed.',
                      );
                      return;
                    }
                    setState(() => _month = e.monthKey);
                    _load(e);
                  },
                  onDelete: () => _delete(e),
                ),
            ],
            if (history.hasError && saved.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ErrorRetry(
                  message: friendlyMessage(history.error),
                  onRetry: () => ref.invalidate(footprintHistoryProvider),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData _modeIcon(String key) => switch (key) {
      'car_petrol' || 'car_diesel' => Icons.directions_car_rounded,
      'motorbike' => Icons.two_wheeler_rounded,
      'taxi' => Icons.local_taxi_rounded,
      'bus' => Icons.directions_bus_rounded,
      'rail' => Icons.train_rounded,
      _ => Icons.flight_rounded,
    };

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 10),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.forest,
              ),
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.hint,
    required this.icon,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final String hint;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: const [DecimalFormatter()],
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            helperMaxLines: 2,
            suffixText: suffix,
            prefixIcon: Icon(icon),
          ),
        ),
      );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DharaCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
                    const SizedBox(height: 2),
                    Text(hint, style: const TextStyle(fontSize: 11, height: 1.35, fontWeight: FontWeight.w500, color: AppColors.inkFaint)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'One fewer',
                onPressed: value > min ? () => onChanged(value - 1) : null,
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
              SizedBox(
                width: 26,
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.forest),
                ),
              ),
              IconButton(
                tooltip: 'One more',
                onPressed: value < max ? () => onChanged(value + 1) : null,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
        ),
      );
}

class _StaleNote extends StatelessWidget {
  const _StaleNote();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          children: [
            Icon(Icons.edit_note_rounded, size: 20, color: AppColors.amber),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'You changed the numbers. Tap "Work it out" again to update the result.',
                style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: AppColors.inkSoft),
              ),
            ),
          ],
        ),
      );
}

class _ResultCard extends ConsumerWidget {
  const _ResultCard({required this.result});

  final FootprintResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final species = ref.watch(speciesProvider).value;
    final trees = ref.watch(treesControllerProvider).value ?? const [];
    final co2 = species == null ? null : computeTreeCo2(species, trees);
    final c = result.comparison;

    return DharaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This month', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.inkSoft)),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: formatCo2(result.monthKg),
                style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: AppColors.forest, height: 1.05),
              ),
              const TextSpan(
                text: '  CO\u2082e',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.inkSoft),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          Text(
            'About ${formatCo2(result.yearKg)} a year if every month looked like this.',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.inkSoft),
          ),
          const SizedBox(height: 18),
          GroupSplitBar(groups: result.groups),
          const Divider(height: 30, color: AppColors.outline),
          for (final l in result.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(l.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink)),
                        if (l.isApproximate) ApproximateTag(confidence: l.confidence),
                      ],
                    ),
                  ),
                  Text(
                    formatKg(l.kg),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.forest),
                  ),
                ],
              ),
            ),
          const Divider(height: 30, color: AppColors.outline),
          const Text('For scale', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.forest)),
          const SizedBox(height: 8),
          _ScaleBar(label: 'You (home energy and travel)', kg: result.yearKg, max: c.worldKgYear > result.yearKg ? c.worldKgYear : result.yearKg, color: AppColors.green),
          _ScaleBar(label: 'India, average per person (${c.indiaYear})', kg: c.indiaKgYear, max: c.worldKgYear > result.yearKg ? c.worldKgYear : result.yearKg, color: AppColors.inkFaint),
          _ScaleBar(label: 'World, average per person (${c.worldYear})', kg: c.worldKgYear, max: c.worldKgYear > result.yearKg ? c.worldKgYear : result.yearKg, color: AppColors.inkFaint),
          const SizedBox(height: 6),
          const Text(
            'The national figures count every sector, including industry, so '
            'this shows scale rather than a score.',
            style: TextStyle(fontSize: 10.5, height: 1.4, fontWeight: FontWeight.w500, color: AppColors.inkFaint),
          ),
          if (co2 != null && result.yearKg > 0) ...[
            const Divider(height: 30, color: AppColors.outline),
            const Text('Against trees', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.forest)),
            const SizedBox(height: 8),
            Text(
              _treeLine(co2, result.yearKg),
              style: const TextStyle(fontSize: 12.5, height: 1.5, fontWeight: FontWeight.w600, color: AppColors.ink),
            ),
            const SizedBox(height: 6),
            const Text(
              'Young trees take in far less while they grow. This is a reality '
              'check, not an offset.',
              style: TextStyle(fontSize: 10.5, height: 1.4, fontWeight: FontWeight.w500, color: AppColors.inkFaint),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Emission factors version ${result.factorsVersion}. Lines marked '
            '"approximate" use UK government figures.',
            style: const TextStyle(fontSize: 10.5, height: 1.4, fontWeight: FontWeight.w500, color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}

/// The trees sentence. Public so it can be tested without building the screen.
String treeComparison(TreeCo2 co2, double yearKg) => _treeLine(co2, yearKg);

String _treeLine(TreeCo2 co2, double yearKg) {
  final needed = (yearKg / co2.avgKgPerYear).ceil();
  final base = 'It would take about $needed average grown trees a year to take '
      'in ${formatCo2(yearKg)}.';
  if (co2.myLivingTrees == 0) return base;

  final share = co2.myKgPerYear / yearKg * 100;
  final pct = share < 1 ? '<1' : share.round().toString();
  final trees = co2.myLivingTrees == 1 ? 'Your tree' : 'Your ${co2.myLivingTrees} trees';
  return '$base $trees will take in about ${formatKg(co2.myKgPerYear)} a year '
      'once grown \u2014 about $pct% of this.';
}

class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.label, required this.kg, required this.max, required this.color});

  final String label;
  final double kg;
  final double max;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.inkSoft))),
                Text(formatCo2(kg), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: AppColors.forest)),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: max <= 0 ? 0 : (kg / max).clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: AppColors.surfaceMuted,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
        ),
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onOpen, required this.onDelete});

  final FootprintEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DharaCard(
          onTap: onOpen,
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.forest)),
                    const SizedBox(height: 2),
                    Text(
                      '${formatCo2(entry.monthKg)} CO\u2082e',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.inkSoft),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Delete ${entry.label}',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.inkFaint),
              ),
            ],
          ),
        ),
      );
}
