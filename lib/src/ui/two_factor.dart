
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import '../storage.dart';
import '../totp.dart';
import 'theme.dart';

/// Draws a QR code (always dark modules on white, so phones can scan it in dark mode too).
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key, this.size = 220});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final img = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: SizedBox.square(dimension: size, child: CustomPaint(painter: _QrPainter(img))),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.img);
  final QrImage img;

  @override
  void paint(Canvas canvas, Size size) {
    final n = img.moduleCount;
    final cell = size.width / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (img.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.img != img;
}

/// Six-digit code entry used by the setup wizard, the disable dialog and the connect prompt.
class CodeField extends StatelessWidget {
  const CodeField({super.key, required this.controller, this.onSubmitted, this.error});
  final TextEditingController controller;
  final void Function(String)? onSubmitted;
  final String? error;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 6,
        style: const TextStyle(fontSize: 28, letterSpacing: 10, fontFeatures: [FontFeature.tabularFigures()]),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(border: const OutlineInputBorder(), counterText: '', hintText: '000000', errorText: error),
        onSubmitted: onSubmitted,
      );
}

/// Asks for the authenticator code when connecting to a device with 2FA on.
Future<String?> askTotpCode(BuildContext context, String deviceName) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    animationStyle: dialogAnimation(),
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.verified_user_outlined),
      title: Text('$deviceName uses two-factor authentication'),
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the 6-digit code from your authenticator app.'),
          const SizedBox(height: 16),
          CodeField(controller: c, onSubmitted: (v) => v.length == 6 ? Navigator.pop(ctx, v) : null),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Connect')),
      ],
    ),
  );
}

/// Two-step setup: scan the QR code (or type the key) → Next → confirm with a code.
Future<bool> setupTwoFactor(BuildContext context, AppStore store) async {
  final secret = newTotpSecret();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    animationStyle: dialogAnimation(),
    builder: (ctx) => _SetupDialog(secret: secret, account: store.deviceName),
  );
  if (ok != true) return false;
  store.totpSecret = secret;
  await store.save();
  return true;
}

class _SetupDialog extends StatefulWidget {
  const _SetupDialog({required this.secret, required this.account});
  final Uint8List secret;
  final String account;
  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  int _step = 0;
  bool _manual = false;
  final _code = TextEditingController();
  String? _error;
  bool _checking = false;

  Future<void> _verify() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await totpVerify(widget.secret, _code.text) != null;
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _checking = false;
        _error = 'That code doesn\'t match. Check the time on your phone and try the newest code.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final key = formatSecret(widget.secret);
    return AlertDialog(
      title: Text(_step == 0 ? 'Set up two-factor authentication' : 'Enter the code'),
      content: SizedBox(
        width: 380,
        child: _step == 0
            ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('1. Open your authenticator app (Google Authenticator, Microsoft Authenticator, Authy, 1Password…) '
                    'and add an account.'),
                const SizedBox(height: 8),
                Text(_manual ? '2. Choose "Enter a setup key" and type this key (time-based):' : '2. Scan this QR code:'),
                const SizedBox(height: 14),
                Center(
                  child: _manual
                      ? Column(children: [
                          SelectableText(key, textAlign: TextAlign.center,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.5)),
                          const SizedBox(height: 6),
                          Text('Account: Localview (${widget.account})', style: t.bodySmall),
                          TextButton.icon(
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy key'),
                            onPressed: () => Clipboard.setData(ClipboardData(text: key.replaceAll(' ', ''))),
                          ),
                        ])
                      : QrView(totpUri(widget.secret, widget.account)),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _manual = !_manual),
                    child: Text(_manual ? 'Show the QR code instead' : 'Can\'t scan? Type the code manually'),
                  ),
                ),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Type the 6-digit code your authenticator app shows for Localview.'),
                const SizedBox(height: 16),
                CodeField(controller: _code, error: _error, onSubmitted: (_) => _verify()),
              ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        if (_step == 1) TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Back')),
        FilledButton(
          onPressed: _checking ? null : (_step == 0 ? () => setState(() => _step = 1) : _verify),
          child: Text(_step == 0 ? 'Next' : 'Turn on'),
        ),
      ],
    );
  }
}

/// Turning 2FA off requires a current code.
Future<bool> disableTwoFactor(BuildContext context, AppStore store) async {
  final c = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    animationStyle: dialogAnimation(),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> check() async {
          if (await totpVerify(store.totpSecret!, c.text) != null) {
            if (ctx.mounted) Navigator.pop(ctx, true);
          } else {
            set(() => error = 'Wrong code.');
          }
        }

        return AlertDialog(
          title: const Text('Turn off two-factor authentication'),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Enter the current code from your authenticator app to confirm.'),
              const SizedBox(height: 16),
              CodeField(controller: c, error: error, onSubmitted: (_) => check()),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: check, child: const Text('Turn off')),
          ],
        );
      },
    ),
  );
  if (ok != true) return false;
  store.totpSecret = null;
  await store.save();
  return true;
}
