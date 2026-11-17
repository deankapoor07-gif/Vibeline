// The licence window, and the screen shown when the trial has ended.
import 'package:flutter/material.dart';

import 'licence.dart';
import 'rig.dart';

const _pink = Color(0xFFEC4FC6);

Widget _wordmark() => const Column(mainAxisSize: MainAxisSize.min, children: [
      Text('D-JAY', style: TextStyle(fontSize: 34, height: 1, letterSpacing: 2, fontWeight: FontWeight.w900, color: Colors.white)),
      SizedBox(height: 5),
      Text('NOODLES', style: TextStyle(fontSize: 15, height: 1, letterSpacing: 6, fontWeight: FontWeight.w700, color: _pink)),
    ]);

/// Shows the app, unless the trial had already ended when it opened. The
/// check is made once at launch, so a set that's playing is never cut off.
class LicenceGate extends StatefulWidget {
  final Widget child;
  final Licence? licence;
  const LicenceGate({super.key, required this.child, this.licence});

  @override
  State<LicenceGate> createState() => _LicenceGateState();
}

class _LicenceGateState extends State<LicenceGate> {
  late final Licence _licence = widget.licence ?? Licence.instance;
  bool? _locked;

  @override
  void initState() {
    super.initState();
    () async {
      if (!_licence.loaded) await _licence.load();
      await _licence.recheck();
      if (mounted) setState(() => _locked = _licence.state == LicenceState.expired);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _locked;
    if (locked == null) return const ColoredBox(color: Color(0xFF0C0C11));
    if (!locked) return widget.child;
    return Scaffold(
      backgroundColor: const Color(0xFF0C0C11),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _wordmark(),
              const SizedBox(height: 28),
              const Text('YOUR FREE TRIAL HAS ENDED', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Buy D-Jay Noodles to keep mixing. Your songs, the songs it has prepared, and your saved mixes are all still here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 22),
              LicencePanel(licence: _licence, showTrial: false, onActivated: () => setState(() => _locked = false)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The trial / licence window opened from the top bar.
Future<void> showLicenceWindow(BuildContext context, {Licence? licence}) => showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kRigFace,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRigCorner)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LicencePanel(licence: licence ?? Licence.instance, onClose: () => Navigator.of(ctx).pop()),
          ),
        ),
      ),
    );

class LicencePanel extends StatefulWidget {
  final Licence licence;
  final bool showTrial;
  final VoidCallback? onActivated;
  final VoidCallback? onClose;
  const LicencePanel({super.key, required this.licence, this.showTrial = true, this.onActivated, this.onClose});

  @override
  State<LicencePanel> createState() => _LicencePanelState();
}

class _LicencePanelState extends State<LicencePanel> {
  final _field = TextEditingController();
  bool _working = false;
  String? _message;
  bool _ok = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run(Future<ActivationResult> Function() job, {VoidCallback? then}) async {
    setState(() {
      _working = true;
      _message = null;
    });
    final r = await job();
    if (!mounted) return;
    setState(() {
      _working = false;
      _ok = r.ok;
      _message = r.message.isEmpty ? null : r.message;
    });
    if (r.ok) then?.call();
  }

  Future<void> _moveOff() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move licence off this Mac?'),
        content: const Text('D-Jay Noodles will stop working on this Mac until a key is entered again. Use this before moving to a new Mac, so the key can go on that one.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move it off')),
        ],
      ),
    );
    if (sure == true) await _run(widget.licence.deactivate);
  }

  static const _small = TextStyle(fontSize: 12, color: Colors.white60, height: 1.4);

  @override
  Widget build(BuildContext context) {
    final l = widget.licence;
    return ListenableBuilder(
      listenable: l,
      builder: (context, _) {
        final children = <Widget>[];
        if (widget.onClose != null) {
          children.add(const Text('LICENCE', style: TextStyle(fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.w700)));
          children.add(const SizedBox(height: 14));
        }
        if (l.licensed) {
          children.addAll([
            const Row(children: [
              Icon(Icons.verified, size: 18, color: kRigGreen),
              SizedBox(width: 8),
              Text('Activated on this Mac', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            Text('Key ${l.maskedKey}', style: _small),
            const SizedBox(height: 4),
            const Text('Your key works on up to 3 Macs. It keeps working offline.', style: _small),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 8, children: [
              if (widget.onClose != null) FilledButton(onPressed: widget.onClose, child: const Text('Done')),
              OutlinedButton(onPressed: _working ? null : _moveOff, child: const Text('Move licence off this Mac')),
            ]),
          ]);
        } else {
          if (widget.showTrial) {
            final left = l.trialDaysLeft;
            children.addAll([
              Text(left > 0 ? 'Free trial: $left ${left == 1 ? 'day' : 'days'} left' : 'Your free trial has ended',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kRigAmber)),
              const SizedBox(height: 4),
              const Text('Everything works during the trial. Buy once to keep it: no subscription.', style: _small),
              const SizedBox(height: 16),
            ]);
          }
          children.addAll([
            TextField(
              controller: _field,
              enabled: !_working,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Licence key',
                hintText: 'Paste the key from your receipt email',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(kRigCorner))),
                isDense: true,
              ),
              onSubmitted: (_) => _run(() => l.activate(_field.text), then: widget.onActivated),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _pink, foregroundColor: Colors.white),
                onPressed: _working ? null : Licence.openShop,
                child: const Text('BUY'),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _working ? null : () => _run(() => l.activate(_field.text), then: widget.onActivated),
                child: Text(_working ? 'Checking…' : 'Activate'),
              ),
              if (widget.onClose != null) TextButton(onPressed: widget.onClose, child: const Text('Close')),
            ]),
          ]);
        }
        if (_message != null) {
          children.addAll([
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(fontSize: 12, height: 1.4, color: _ok ? kRigGreen : const Color(0xFFFF6B6B))),
          ]);
        }
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }
}
