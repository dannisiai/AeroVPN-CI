import 'package:flutter/foundation.dart';
import '../config/i18n.dart';
import '../core/security/secure_vault.dart';

class LocaleProvider extends ChangeNotifier {
  final SecureVault _vault;
  String _currentLanguage = 'zh';

  LocaleProvider(this._vault);

  String get currentLanguage => _currentLanguage;

  Future<void> initLocale() async {
    _currentLanguage = await _vault.getLanguage();
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    if (_currentLanguage == lang) return;
    _currentLanguage = lang;
    await _vault.setLanguage(lang);
    notifyListeners();
  }

  /// Shorthand translation method: t('key')
  String t(String key) {
    return AppI18n.tr(key, _currentLanguage);
  }
}
