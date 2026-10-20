import 'package:solis_mobile/models/provider_profile.dart';

/// A complete, non-demo billing identity for claim tests. The demo
/// provider's NPI and tax ID are refused on real claims (CLAIM-PROVIDER-01),
/// so tests that are about coding use this one. 1234567893 passes the NPI
/// check digit; it is the CMS example NPI.
ProviderProfile testProvider() => ProviderProfile.demo().copyWith(npi: '1234567893', taxId: '12-3456789');
