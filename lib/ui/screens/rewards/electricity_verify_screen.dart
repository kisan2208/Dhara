import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/haptics.dart';
import '../../../core/utils/validators.dart';
import '../../../state/rewards_controller.dart';
import '../../widgets/camera_capture.dart';
import '../../widgets/common.dart';

/// One electricity distributor. [code] is what the server stores.
class _Discom {
  const _Discom(this.code, this.name, this.state);

  final String code;
  final String name;
  final String state;
}

/// A starting set of Indian distributors, enough to cover the major metros.
///
/// "Other" exists so nobody is blocked by an absent discom: the number still
/// gets verified against the bill photo, which is what actually matters.
const _discoms = <_Discom>[
  _Discom('BESCOM', 'BESCOM', 'Karnataka'),
  _Discom('MSEDCL', 'MSEDCL (Mahavitaran)', 'Maharashtra'),
  _Discom('TNEB', 'TNEB / TANGEDCO', 'Tamil Nadu'),
  _Discom('TSSPDCL', 'TSSPDCL', 'Telangana'),
  _Discom('APEPDCL', 'APEPDCL', 'Andhra Pradesh'),
  _Discom('BSES', 'BSES Rajdhani / Yamuna', 'Delhi'),
  _Discom('TPDDL', 'Tata Power DDL', 'Delhi'),
  _Discom('CESC', 'CESC', 'West Bengal'),
  _Discom('MGVCL', 'MGVCL / Torrent', 'Gujarat'),
  _Discom('KSEB', 'KSEB', 'Kerala'),
  _Discom('JVVNL', 'JVVNL', 'Rajasthan'),
  _Discom('UPPCL', 'UPPCL', 'Uttar Pradesh'),
  _Discom('MPPKVVCL', 'MPPKVVCL', 'Madhya Pradesh'),
  _Discom('PSPCL', 'PSPCL', 'Punjab'),
  _Discom('OTHER', 'Other provider', ''),
];

/// Links an electricity account so credits can be spent against a bill.
///
/// Asked for once. The number is checked two ways: its shape locally, then
/// against text read out of the bill photo on-device. Nothing is trusted from
/// this screen — the server re-reads the OCR text and decides.
class ElectricityVerifyScreen extends ConsumerStatefulWidget {
  const ElectricityVerifyScreen({super.key});

  static Future<void> push(BuildContext context) {
    Haptics.tap();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const ElectricityVerifyScreen()),
    );
  }

  @override
  ConsumerState<ElectricityVerifyScreen> createState() =>
      _ElectricityVerifyScreenState();
}

class _ElectricityVerifyScreenState
    extends ConsumerState<ElectricityVerifyScreen> {
  final _form = GlobalKey<FormState>();
  final _consumerNo = TextEditingController();
  final _holderName = TextEditingController();

  _Discom _discom = _discoms.first;
  String? _billPath;
  bool _reading = false;
  bool _submitting = false;
  BillSubmission? _result;

  @override
  void dispose() {
    _consumerNo.dispose();
    _holderName.dispose();
    super.dispose();
  }

  Future<void> _captureBill() async {
    final path = await CameraCaptureScreen.push(
      context,
      title: 'Photograph your bill',
      hint: 'Make sure the consumer number is sharp and fully in frame.',
    );
    if (path == null || !mounted) return;

    setState(() {
      _billPath = path;
      _reading = true;
    });

    try {
      final guess = await ref
          .read(rewardsControllerProvider.notifier)
          .guessConsumerNumber(path);

      if (!mounted) return;
      setState(() => _reading = false);

      // Only prefill an empty field: never overwrite what the user typed.
      if (guess != null && _consumerNo.text.trim().isEmpty) {
        _consumerNo.text = guess;
        Haptics.success();
        showSnack(context, 'Found a number on the bill. Check it is right.');
      }
    } catch (_) {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (!(_form.currentState?.validate() ?? false)) {
      Haptics.warn();
      return;
    }
    if (_billPath == null) {
      Haptics.warn();
      showSnack(context, 'Add a photo of your bill first.', isError: true);
      return;
    }

    Haptics.press();
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);

    try {
      final result =
          await ref.read(rewardsControllerProvider.notifier).submitBill(
                photoPath: _billPath!,
                // Normalised so what is validated is exactly what is sent.
                consumerNo: Validate.normalizeConsumerNo(_consumerNo.text),
                provider: _discom.name,
                providerCode: _discom.code,
                holderName: _holderName.text.trim().isEmpty
                    ? null
                    : _holderName.text.trim(),
                stateName: _discom.state.isEmpty ? null : _discom.state,
              );

      if (!mounted) return;
      result.verified ? Haptics.celebrate() : Haptics.warn();
      setState(() {
        _result = result;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _submitting = false);
      showSnack(context, friendlyMessage(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Electricity account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _submitting
              ? null
              : () {
                  Haptics.tap();
                  Navigator.of(context).pop();
                },
        ),
      ),
      body: SafeArea(
        child: _result == null ? _formView() : _resultView(_result!),
      ),
    );
  }

  Widget _formView() {
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Link your bill once',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.forest,
                ),
          ).animate().fadeIn().slideY(begin: 0.2, end: 0),
          const SizedBox(height: 6),
          const Text(
            'We match the number you enter against your bill photo. Everything '
            'is read on your phone.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: AppColors.inkSoft,
            ),
          ).animate(delay: 80.ms).fadeIn(),
          const SizedBox(height: 24),

          _BillPhotoBox(
            path: _billPath,
            reading: _reading,
            onCapture: _submitting ? null : _captureBill,
          ),

          const SizedBox(height: 20),

          DropdownButtonFormField<_Discom>(
            initialValue: _discom,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Your provider',
              prefixIcon: Icon(Icons.bolt_rounded),
            ),
            items: _discoms
                .map(
                  (d) => DropdownMenuItem(
                    value: d,
                    child: Text(
                      d.state.isEmpty ? d.name : '${d.name} \u00B7 ${d.state}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                )
                .toList(),
            onChanged: _submitting
                ? null
                : (value) {
                    if (value == null) return;
                    Haptics.select();
                    setState(() => _discom = value);
                  },
          ).animate(delay: 160.ms).fadeIn().slideY(begin: 0.15, end: 0),

          const SizedBox(height: 16),

          TextFormField(
            controller: _consumerNo,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              // Uppercase as typed so the field shows exactly what is submitted.
              TextInputFormatter.withFunction(
                (_, next) => next.copyWith(text: next.text.toUpperCase()),
              ),
              FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9\- ]')),
              LengthLimitingTextInputFormatter(24),
            ],
            decoration: const InputDecoration(
              labelText: 'Consumer number',
              helperText: 'Printed near the top of your bill',
              prefixIcon: Icon(Icons.pin_rounded),
            ),
            validator: Validate.consumerNo,
          ).animate(delay: 220.ms).fadeIn().slideY(begin: 0.15, end: 0),

          const SizedBox(height: 16),

          TextFormField(
            controller: _holderName,
            textCapitalization: TextCapitalization.words,
            inputFormatters: [LengthLimitingTextInputFormatter(128)],
            decoration: const InputDecoration(
              labelText: 'Name on the bill (optional)',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ).animate(delay: 280.ms).fadeIn().slideY(begin: 0.15, end: 0),

          const SizedBox(height: 26),

          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Verify my account'),
          ).animate(delay: 340.ms).fadeIn(),

          const SizedBox(height: 14),
          const Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.inkFaint),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Only the last four digits are ever shown back to you.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkFaint,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultView(BillSubmission result) {
    final verified = result.verified;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      children: [
        Center(
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: (verified ? AppColors.green : AppColors.amber)
                  .withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(
                verified
                    ? Icons.verified_rounded
                    : Icons.hourglass_bottom_rounded,
                size: 44,
                color: verified ? AppColors.green : AppColors.amber,
              ),
            ),
          )
              .animate()
              .scale(duration: 480.ms, curve: Curves.easeOutBack)
              .fadeIn(),
        ),
        const SizedBox(height: 24),
        Text(
          verified
              ? 'Account verified'
              : result.alreadyLinked
                  ? 'Already on file'
                  : 'Sent for review',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppColors.forest,
          ),
        ).animate(delay: 100.ms).fadeIn(),
        const SizedBox(height: 10),
        Text(
          result.message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: AppColors.inkSoft,
          ),
        ).animate(delay: 160.ms).fadeIn(),
        if (!verified) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Text(
              'Your credits are safe. Once a reviewer confirms the number you '
              'will be able to redeem against your bill, usually within 48 '
              'hours.',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: AppColors.inkSoft,
              ),
            ),
          ).animate(delay: 220.ms).fadeIn(),
        ],
        const SizedBox(height: 28),
        FilledButton(
          onPressed: () {
            Haptics.tap();
            Navigator.of(context).pop();
          },
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _BillPhotoBox extends StatelessWidget {
  const _BillPhotoBox({
    required this.path,
    required this.reading,
    required this.onCapture,
  });

  final String? path;
  final bool reading;
  final VoidCallback? onCapture;

  @override
  Widget build(BuildContext context) {
    final p = path;

    if (p == null) {
      return DharaCard(
        onTap: onCapture,
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
        child: Column(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Icon(
                  Icons.receipt_long_rounded,
                  size: 26,
                  color: AppColors.green,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Photograph your bill',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: AppColors.forest,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'We will try to read the consumer number for you',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.inkSoft,
              ),
            ),
          ],
        ),
      ).animate(delay: 120.ms).fadeIn().slideY(begin: 0.12, end: 0);
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.file(
            File(p),
            height: 190,
            width: double.infinity,
            fit: BoxFit.cover,
            // The file is written by the camera moments earlier; if it cannot
            // be decoded the retake button below is still reachable.
            errorBuilder: (_, _, _) => Container(
              height: 190,
              color: AppColors.surfaceMuted,
              child: const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.inkFaint,
                ),
              ),
            ),
          ),
        ),
        if (reading)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Reading your bill\u2026',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          right: 10,
          bottom: 10,
          child: FilledButton.icon(
            onPressed: onCapture,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Retake'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.6),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    ).animate().fadeIn();
  }
}
