import '../models/ambulance_transport.dart' show haversineMiles;
import '../models/patient_account.dart';
import '../models/provider_profile.dart';

const _metersPerMile = 1609.344;

/// The saved place a location fix falls inside, nearest first. Null when
/// the fix is missing, too imprecise to tell places apart (accuracy worse
/// than [maxAccuracyMeters]) or outside every place.
SavedPlace? matchSavedPlace(List<SavedPlace> places, Map<String, dynamic>? gps, {double maxAccuracyMeters = 200}) {
  if (gps == null || gps['available'] != true || places.isEmpty) return null;
  final lat = (gps['latitude'] as num?)?.toDouble();
  final lng = (gps['longitude'] as num?)?.toDouble();
  if (lat == null || lng == null) return null;
  final acc = (gps['accuracy'] as num?)?.toDouble();
  if (acc != null && acc > maxAccuracyMeters) return null;
  SavedPlace? best;
  var bestMeters = double.infinity;
  for (final p in places) {
    final meters = haversineMiles(lat, lng, p.latitude, p.longitude) * _metersPerMile;
    if (meters <= p.radiusMeters && meters < bestMeters) {
      best = p;
      bestMeters = meters;
    }
  }
  return best;
}

/// Where a new visit's place of service came from.
class PosChoice {
  final String code;

  /// 'place' (a saved place matched the location), 'last visit' or 'default'.
  final String source;
  final String? placeName;

  const PosChoice(this.code, this.source, {this.placeName});

  String get explanation => switch (source) {
        'place' => 'At ${placeName ?? 'a saved place'}',
        'last visit' => 'Same as the last visit',
        _ => 'Your usual place of service',
      };
}

/// Picks the place of service for a new visit, in order: a saved place
/// matching the location fix, this patient's last visit if it was within
/// [recent], then the profile default. Every choice stays visible and
/// changeable on the visit.
PosChoice choosePlaceOfService({
  required ProviderProfile provider,
  required PatientAccount account,
  Map<String, dynamic>? gps,
  DateTime? now,
  Duration recent = const Duration(days: 30),
}) {
  final place = matchSavedPlace(provider.savedPlaces, gps);
  if (place != null) return PosChoice(place.placeOfService, 'place', placeName: place.name);
  final today = now ?? DateTime.now();
  Visit? last;
  for (final v in account.visits) {
    if (last == null || v.number > last.number) last = v;
  }
  final lastDate = last == null ? null : DateTime.tryParse(last.dateOfService);
  if (last != null && lastDate != null && today.difference(lastDate) <= recent) {
    return PosChoice(last.placeOfService, 'last visit');
  }
  return PosChoice(provider.defaultPlaceOfService, 'default');
}
