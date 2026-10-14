import 'package:flutter/foundation.dart';
import '../core/api/api_client.dart';
import '../core/api/api_models.dart';

class RegionProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  List<RegionModel> _regions = [];
  RegionModel? _selectedRegion;
  CityModel? _selectedCity;
  bool _isLoading = false;
  String? _errorMessage;

  RegionProvider(this._apiClient);

  List<RegionModel> get regions => _regions;
  RegionModel? get selectedRegion => _selectedRegion;
  CityModel? get selectedCity => _selectedCity;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> fetchRegions() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _regions = await _apiClient.getRegions();
      if (_regions.isNotEmpty && _selectedRegion == null) {
        // Default to fastest or recommended region
        final best = getFastestTarget();
        _selectedRegion = best.region;
        _selectedCity = best.city;
      }
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void selectLocation(RegionModel region, [CityModel? city]) {
    _selectedRegion = region;
    _selectedCity = city ?? region.defaultCity;
    notifyListeners();
  }

  /// Commercial Quick Connect Scoring Algorithm
  /// Calculates optimal server: Score = Latency * 0.7 + Load * 0.3
  ({RegionModel region, CityModel city}) getFastestTarget() {
    if (_regions.isEmpty) {
      final fallbackCity = CityModel(id: 'us-1', name: '节点 1', latencyMs: 26, loadPercent: 15, features: ['hy2']);
      final fallbackRegion = RegionModel(id: 'us', name: 'United States', code: 'US', flagEmoji: '🇺🇸', recommended: true, cities: [fallbackCity]);
      return (region: fallbackRegion, city: fallbackCity);
    }

    RegionModel bestRegion = _regions.first;
    CityModel bestCity = bestRegion.defaultCity;
    double minScore = double.infinity;

    for (final region in _regions) {
      for (final city in region.cities) {
        final score = (city.latencyMs * 0.7) + (city.loadPercent * 0.3);
        if (score < minScore) {
          minScore = score;
          bestRegion = region;
          bestCity = city;
        }
      }
    }

    return (region: bestRegion, city: bestCity);
  }
}
