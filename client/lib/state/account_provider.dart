import 'package:flutter/foundation.dart';
import '../core/api/api_client.dart';
import '../core/api/api_models.dart';

class AccountProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  PlanModel? _plan;
  bool _isLoading = false;
  String? _errorMessage;

  AccountProvider(this._apiClient);

  PlanModel? get plan => _plan;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> fetchAccount() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _plan = await _apiClient.getAccount();
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
