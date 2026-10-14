import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../core/api/api_models.dart';
import '../../state/locale_provider.dart';

class RegionPickerSheet extends StatefulWidget {
  final List<RegionModel> regions;
  final RegionModel? currentRegion;
  final CityModel? currentCity;
  final Function(RegionModel region, CityModel city) onSelectLocation;

  const RegionPickerSheet({
    super.key,
    required this.regions,
    required this.currentRegion,
    required this.currentCity,
    required this.onSelectLocation,
  });

  @override
  State<RegionPickerSheet> createState() => _RegionPickerSheetState();
}

class _RegionPickerSheetState extends State<RegionPickerSheet> {
  String _searchQuery = '';
  final Set<String> _expandedRegionIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.currentRegion != null) {
      _expandedRegionIds.add(widget.currentRegion!.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();
    final filteredRegions = widget.regions.where((r) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      final matchRegion = r.name.toLowerCase().contains(q) || r.code.toLowerCase().contains(q);
      final matchCity = r.cities.any((c) => c.name.toLowerCase().contains(q));
      return matchRegion || matchCity;
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.cardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  locale.t('select_server_location'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppTheme.textSecondary),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Search box
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: locale.t('search_placeholder'),
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18, color: AppTheme.textMuted),
                        onPressed: () => setState(() => _searchQuery = ''),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Server List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: filteredRegions.length,
              itemBuilder: (context, index) {
                final region = filteredRegions[index];
                final isExpanded = _expandedRegionIds.contains(region.id) || _searchQuery.isNotEmpty;

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.cardBorder),
                  ),
                  child: Column(
                    children: [
                      // Country Header Tile
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                        leading: Text(region.flagEmoji, style: const TextStyle(fontSize: 24)),
                        title: Row(
                          children: [
                            Text(
                              region.name,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            if (region.recommended) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  locale.t('popular'),
                                  style: const TextStyle(color: AppTheme.primary, fontSize: 9, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${region.cities.length} ${locale.t('locations_count')}',
                          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                            color: AppTheme.textSecondary,
                          ),
                          onPressed: () {
                            setState(() {
                              if (_expandedRegionIds.contains(region.id)) {
                                _expandedRegionIds.remove(region.id);
                              } else {
                                _expandedRegionIds.add(region.id);
                              }
                            });
                          },
                        ),
                      ),
                      // Cities List
                      if (isExpanded)
                        Container(
                          decoration: const BoxDecoration(
                            border: Border(top: BorderSide(color: AppTheme.cardBorder, width: 0.8)),
                          ),
                          child: Column(
                            children: region.cities.map((city) {
                              final isSelected = widget.currentRegion?.id == region.id && widget.currentCity?.id == city.id;
                              return InkWell(
                                onTap: () {
                                  widget.onSelectLocation(region, city);
                                  Navigator.pop(context);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isSelected ? AppTheme.primary.withValues(alpha: 0.08) : Colors.transparent,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.dns_rounded, size: 16, color: AppTheme.textMuted),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          city.name,
                                          style: TextStyle(
                                            color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      // Latency Dot & Value
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: city.latencyMs < 60 ? AppTheme.statusConnected : AppTheme.statusConnecting,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${city.latencyMs} ms',
                                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                                      ),
                                      const SizedBox(width: 12),
                                      if (isSelected)
                                        const Icon(Icons.check_circle_rounded, color: AppTheme.primary, size: 18)
                                      else
                                        const SizedBox(width: 18),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
