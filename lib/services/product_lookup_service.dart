import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/category_model.dart';
import 'category_classifier.dart';
import '../models/product_model.dart';
import '../utils/barcode_utils.dart';

/// Overall outcome of a barcode lookup. Each is a different situation for the user:
/// a bad number is not the same as a product missing from the databases.
enum LookupStatus {
  found,
  notFound, // every database answered "no record" for a valid barcode
  invalidFormat, // not an EAN/UPC barcode (letters, wrong length); nothing was looked up
  invalidCheckDigit, // a digit is wrong somewhere; nothing was looked up
  offline, // no database could be reached
  timeout, // databases did not answer in time
  unavailable, // some databases failed (server error / rate limit) and none had the product
}

/// What one database said, for diagnostics (no personal data).
enum AttemptOutcome { found, notFound, rejected, serverError, rateLimited, timeout, unreachable, malformed }

class LookupAttempt {
  final String source;
  final AttemptOutcome outcome;
  final String? detail;
  const LookupAttempt(this.source, this.outcome, [this.detail]);
  @override
  String toString() => '$source: ${outcome.name}${detail != null ? ' ($detail)' : ''}';
}

/// One product returned by a name/brand search.
class ProductSearchCandidate {
  final String barcode;
  final String name;
  final String brand;
  final String? quantity;
  final String? imageUrl;
  const ProductSearchCandidate({
    required this.barcode,
    required this.name,
    required this.brand,
    this.quantity,
    this.imageUrl,
  });
}

class ProductSearchResult {
  final List<ProductSearchCandidate> candidates;
  final String? errorMessage;
  const ProductSearchResult(this.candidates, [this.errorMessage]);
}

class ProductLookupResult {
  /// True only when a real product record was found (curated catalog or an online
  /// database). A barcode that was read but is unknown is `found: false`.
  final bool found;
  final LookupStatus status;

  /// What each database said (in order), for diagnostics.
  final List<LookupAttempt> attempts;

  /// Barcode format identified before the lookup (e.g. "EAN-13", "UPC-E").
  final String? formatLabel;
  final ProductModel? product;
  final String? rawResponse;
  final String? errorMessage;
  final String? source;

  /// Normalized digits that were looked up (null when the input was not a product barcode).
  final String? barcode;

  /// True when no online database could be reached at all (offline, DNS, timeouts).
  final bool networkError;

  /// True when the GS1 check digit does not match (likely a typo in manual entry).
  final bool checkDigitInvalid;

  /// Set when the result was served from this device's lookup cache (not fetched now).
  final DateTime? cachedAt;

  /// Required attribution for data from Open Beauty/Food/Products Facts (ODbL), or null.
  final String? attribution;

  /// Link to the source record, when there is one.
  final String? sourceUrl;

  ProductLookupResult({
    required this.found,
    LookupStatus? status,
    this.attempts = const [],
    this.formatLabel,
    this.product,
    this.rawResponse,
    this.errorMessage,
    this.source,
    this.barcode,
    this.networkError = false,
    this.checkDigitInvalid = false,
    this.cachedAt,
    this.attribution,
    this.sourceUrl,
  }) : status = status ??
            (found
                ? LookupStatus.found
                : (checkDigitInvalid
                    ? LookupStatus.invalidCheckDigit
                    : (networkError ? LookupStatus.offline : LookupStatus.notFound)));

  bool get fromCache => cachedAt != null;

  /// True when the record has no usable name or brand and the user must fill them in.
  bool get hasMissingDetails =>
      product != null && (product!.name.trim().isEmpty || product!.brand.trim().isEmpty);
}

/// Thrown internally when a database could not be reached (as opposed to "not found").
class _Unreachable implements Exception {
  final Object cause;
  _Unreachable(this.cause);
  bool get isTimeout => cause is TimeoutException;
}

/// An HTTP answer: status code and the decoded JSON object (null when the body was not a
/// JSON object).
typedef _JsonResponse = ({int statusCode, Map<String, dynamic>? json});

class ProductLookupService {
  static const String _beautyFactsV2Url = 'https://world.openbeautyfacts.org/api/v2/product';
  static const String _foodFactsV2Url = 'https://world.openfoodfacts.org/api/v2/product';
  static const String _productsFactsV2Url = 'https://world.openproductsfacts.org/api/v2/product';
  static const String _upcItemDbUrl = 'https://api.upcitemdb.com/prod/trial/lookup';

  // Open*Facts asks apps to identify themselves as "AppName/Version (contact)". Browsers do
  // not allow setting User-Agent, so it is only sent from mobile/desktop.
  static const _userAgent = 'VanityTracker/1.0 (student project; info@vanitytracker.app)';

  /// Open*Facts data is under the Open Database License; reusers must attribute it.
  static const openFactsAttribution =
      'Product data from Open Beauty Facts / Open Food Facts contributors, available under the '
      'Open Database License (ODbL): https://world.openbeautyfacts.org';

  /// Cached lookups are reused for this long before asking the database again
  /// (the Open*Facts APIs allow about 15 product reads per minute).
  static const cacheTtl = Duration(days: 7);
  static const _cacheKey = 'product_lookup_cache_v1';

  static Future<Map<String, dynamic>> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {}; // a broken cache is ignored, never fatal
    }
  }

  static Future<void> _writeCache(String barcode, ProductLookupResult r) async {
    try {
      final cache = await _readCache();
      cache[barcode] = {
        'saved_at': DateTime.now().toIso8601String(),
        'source': r.source,
        'source_url': r.sourceUrl,
        'attribution': r.attribution,
        'product': r.product!.toMap(),
      };
      // Keep the cache small.
      if (cache.length > 200) cache.remove(cache.keys.first);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(cache));
    } catch (e) {
      debugPrint('Lookup cache write failed: $e');
    }
  }

  static Future<ProductLookupResult?> _fromCache(String barcode, {required bool allowStale, required bool checkDigitInvalid}) async {
    final entry = (await _readCache())[barcode];
    if (entry is! Map) return null;
    final savedAt = DateTime.tryParse('${entry['saved_at']}');
    final product = entry['product'];
    if (savedAt == null || product is! Map) return null;
    if (!allowStale && DateTime.now().difference(savedAt) > cacheTtl) return null;
    return ProductLookupResult(
      found: true,
      product: ProductModel.fromMap(Map<String, dynamic>.from(product)),
      source: entry['source'] as String?,
      sourceUrl: entry['source_url'] as String?,
      attribution: entry['attribution'] as String?,
      barcode: barcode,
      cachedAt: savedAt,
      checkDigitInvalid: checkDigitInvalid,
    );
  }

  /// GET + JSON decode. Throws [_Unreachable] when the server could not be reached or
  /// did not answer in time; otherwise returns the status code and the JSON object (null
  /// for a body that is not a JSON object).
  static Future<_JsonResponse> _getJson(Uri url, Duration timeout, {bool sendUserAgent = true}) async {
    final http.Response res;
    try {
      res = await http
          .get(url, headers: sendUserAgent && !kIsWeb ? {'User-Agent': _userAgent} : null)
          .timeout(timeout);
    } catch (e) {
      throw _Unreachable(e);
    }
    Map<String, dynamic>? json;
    try {
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) json = data;
    } catch (_) {
      // not JSON
    }
    return (statusCode: res.statusCode, json: json);
  }

  /// Lookups for the same barcode that are already running (rebuilds, repeated scans and
  /// double taps share one set of requests).
  static final Map<String, Future<ProductLookupResult>> _inFlight = {};

  /// Lookup a product by barcode.
  ///
  /// 1. The barcode's format is identified and its check digit validated with that
  ///    format's rule (a UPC-E code is expanded to UPC-A first). A value that is not a
  ///    barcode, or whose check digit fails, is NOT looked up: a wrong digit would only
  ///    produce a misleading "not found". [allowInvalidCheckDigit] lets the user search
  ///    for the number exactly as typed after being told it is probably mistyped.
  /// 2. Open Beauty Facts, then Open Products Facts and Open Food Facts (and UPCitemdb on
  ///    mobile/desktop). A record is only accepted when the database says it found it AND
  ///    the barcode it returns is the one asked for.
  /// 3. "Not found" is only reported when the databases actually answered "no record";
  ///    server errors, rate limits, timeouts and no connection are reported as such.
  ///
  /// Recent results are cached on the device; [forceRefresh] skips the cache. When no
  /// database can be reached, a cached result (even an old one, marked with its date) or
  /// the app's small sample catalog is offered, clearly labelled. Never invents a product.
  static Future<ProductLookupResult> lookupBarcode(
    String barcode, {
    bool forceRefresh = false,
    bool allowInvalidCheckDigit = false,
  }) {
    final key = '${barcode.trim()}|$forceRefresh|$allowInvalidCheckDigit';
    return _inFlight[key] ??= _lookup(barcode, forceRefresh: forceRefresh, allowInvalidCheckDigit: allowInvalidCheckDigit)
        .whenComplete(() {
      _inFlight.remove(key);
    });
  }

  static Future<ProductLookupResult> _lookup(
    String barcode, {
    required bool forceRefresh,
    required bool allowInvalidCheckDigit,
  }) async {
    if (barcode.trim().isEmpty) {
      return ProductLookupResult(found: false, status: LookupStatus.invalidFormat, errorMessage: 'Empty barcode provided');
    }
    final check = BarcodeUtils.check(barcode);
    final cleanBarcode = check.lookupDigits;
    if (cleanBarcode == null) {
      if (kDebugMode) debugPrint('[lookup] rejected before lookup: not a retail barcode');
      return ProductLookupResult(
        found: false,
        status: LookupStatus.invalidFormat,
        errorMessage: '"${barcode.trim()}" is not a product barcode (EAN/UPC: 8, 12, 13 or 14 digits). '
            'Rescan it, correct the number, or enter the details manually.',
      );
    }
    final checkDigitInvalid = !check.checkDigitValid;
    if (checkDigitInvalid && !allowInvalidCheckDigit) {
      if (kDebugMode) debugPrint('[lookup] ${check.formatLabel} check digit failed: not looked up');
      return ProductLookupResult(
        found: false,
        status: LookupStatus.invalidCheckDigit,
        formatLabel: check.formatLabel,
        barcode: cleanBarcode,
        checkDigitInvalid: true,
        errorMessage: '$cleanBarcode is not a valid ${check.formatLabel} barcode: its check digit does not match, so '
            'at least one digit was misread or mistyped. Rescan it or compare the number with the pack. '
            '(The check digit cannot tell which digit is wrong, so the app does not guess.)',
      );
    }

    if (!forceRefresh) {
      final cached = await _fromCache(cleanBarcode, allowStale: false, checkDigitInvalid: checkDigitInvalid);
      if (cached != null) return cached;
    }

    // One request per database (the v2 API answers "not found" with HTTP 404 + status 0,
    // checked against the live API on 2026-10-19; it also returns 5xx during outages).
    final sources = <(String, String, Duration)>[
      ('Open Beauty Facts', _beautyFactsV2Url, const Duration(seconds: 8)),
      // Cosmetic & personal-care crossover products
      ('Open Products Facts', _productsFactsV2Url, const Duration(seconds: 5)),
      ('Open Food Facts', _foodFactsV2Url, const Duration(seconds: 5)),
    ];

    final attempts = <LookupAttempt>[];
    void note(LookupAttempt a) {
      attempts.add(a);
      if (kDebugMode) debugPrint('[lookup] $a'); // barcode and source only: no personal data
    }

    for (final (name, base, timeout) in sources) {
      try {
        final res = await _getJson(Uri.parse('$base/$cleanBarcode.json'), timeout);
        final data = res.json;
        final product = data?['product'];
        if (res.statusCode == 200 && data?['status'] == 1 && product is Map<String, dynamic>) {
          final returned = '${product['code'] ?? data?['code'] ?? ''}';
          if (returned.isNotEmpty && !BarcodeUtils.sameProduct(returned, cleanBarcode)) {
            note(LookupAttempt(name, AttemptOutcome.rejected, 'record is for barcode $returned'));
            continue;
          }
          note(LookupAttempt(name, AttemptOutcome.found));
          final parsed = _parseApiProduct(cleanBarcode, product, name);
          final result = ProductLookupResult(
            found: true,
            attempts: List.unmodifiable(attempts),
            formatLabel: check.formatLabel,
            product: parsed,
            source: name,
            sourceUrl: parsed.barcodeScanUrl,
            attribution: openFactsAttribution,
            barcode: cleanBarcode,
            checkDigitInvalid: checkDigitInvalid,
          );
          await _writeCache(cleanBarcode, result);
          return result;
        }
        note(LookupAttempt(name, _outcomeFor(res)));
      } on _Unreachable catch (e) {
        note(LookupAttempt(name, e.isTimeout ? AttemptOutcome.timeout : AttemptOutcome.unreachable));
      } catch (e) {
        note(LookupAttempt(name, AttemptOutcome.malformed, '$e'));
      }
    }

    // UPCitemdb does not allow browser (CORS) requests, so it only works on mobile/desktop.
    if (!kIsWeb) {
      const name = 'UPCitemdb';
      try {
        final res = await _getJson(Uri.parse('$_upcItemDbUrl?upc=$cleanBarcode'), const Duration(seconds: 5),
            sendUserAgent: false);
        final items = res.json?['items'];
        if (res.statusCode == 200 && items is List && items.isNotEmpty && items.first is Map<String, dynamic>) {
          final item = items.first as Map<String, dynamic>;
          final returned = '${item['ean'] ?? item['upc'] ?? ''}';
          if (returned.isNotEmpty && !BarcodeUtils.sameProduct(returned, cleanBarcode)) {
            note(LookupAttempt(name, AttemptOutcome.rejected, 'record is for barcode $returned'));
          } else {
            note(LookupAttempt(name, AttemptOutcome.found));
            return ProductLookupResult(
              found: true,
              attempts: List.unmodifiable(attempts),
              formatLabel: check.formatLabel,
              product: _parseUpcDbProduct(cleanBarcode, item),
              source: 'UPC Database',
              barcode: cleanBarcode,
              checkDigitInvalid: checkDigitInvalid,
            );
          }
        } else {
          // UPCitemdb answers an unknown code with 200 and no items.
          note(LookupAttempt(name, res.statusCode == 200 && items is List ? AttemptOutcome.notFound : _outcomeFor(res)));
        }
      } on _Unreachable catch (e) {
        note(LookupAttempt(name, e.isTimeout ? AttemptOutcome.timeout : AttemptOutcome.unreachable));
      } catch (e) {
        note(LookupAttempt(name, AttemptOutcome.malformed, '$e'));
      }
    }

    final answered = attempts.where((a) => a.outcome != AttemptOutcome.timeout && a.outcome != AttemptOutcome.unreachable);
    if (answered.isEmpty) {
      // Offline: an earlier lookup of this barcode, however old, is better than nothing,
      // as long as its date is shown. Then the small sample catalog, clearly labelled.
      final stale = await _fromCache(cleanBarcode, allowStale: true, checkDigitInvalid: checkDigitInvalid);
      if (stale != null) return stale;
      for (final candidate in BarcodeUtils.equivalents(cleanBarcode)) {
        final offlineMatch = _lookupLocalCatalog(candidate);
        if (offlineMatch != null) {
          return ProductLookupResult(
            found: true,
            attempts: List.unmodifiable(attempts),
            formatLabel: check.formatLabel,
            product: offlineMatch,
            source: 'Offline sample catalog (unverified)',
            barcode: cleanBarcode,
            checkDigitInvalid: checkDigitInvalid,
            errorMessage: 'Could not reach the product databases. Showing an entry from the app\'s offline sample '
                'catalog: check that the name matches your product.',
          );
        }
      }
      final allTimedOut = attempts.isNotEmpty && attempts.every((a) => a.outcome == AttemptOutcome.timeout);
      return ProductLookupResult(
        found: false,
        status: allTimedOut ? LookupStatus.timeout : LookupStatus.offline,
        attempts: List.unmodifiable(attempts),
        formatLabel: check.formatLabel,
        barcode: cleanBarcode,
        networkError: true,
        checkDigitInvalid: checkDigitInvalid,
        errorMessage: allTimedOut
            ? 'The product databases did not answer in time. Try again, or enter the details manually.'
            : 'Could not reach the product databases (check your internet connection). '
                'Try again, or enter the details manually.',
      );
    }

    // Only a definite "no record" from every database counts as not found.
    if (attempts.any((a) => a.outcome != AttemptOutcome.notFound && a.outcome != AttemptOutcome.rejected)) {
      return ProductLookupResult(
        found: false,
        status: LookupStatus.unavailable,
        attempts: List.unmodifiable(attempts),
        formatLabel: check.formatLabel,
        barcode: cleanBarcode,
        checkDigitInvalid: checkDigitInvalid,
        errorMessage: 'No product record was found for $cleanBarcode, but some databases could not be checked '
            '(${attempts.where((a) => a.outcome != AttemptOutcome.notFound).map((a) => '${a.source}: ${_outcomeText(a.outcome)}').join('; ')}). '
            'Try again later, search by name, or enter the details manually.',
      );
    }

    // A GS1 prefix only tells where the barcode was registered, not the brand or origin,
    // so it is offered as a hint, never as product data.
    final region = _getCountryFromBarcodePrefix(cleanBarcode);
    return ProductLookupResult(
      found: false,
      status: LookupStatus.notFound,
      attempts: List.unmodifiable(attempts),
      formatLabel: check.formatLabel,
      barcode: cleanBarcode,
      checkDigitInvalid: checkDigitInvalid,
      errorMessage: checkDigitInvalid
          ? 'No product found for $cleanBarcode (searched exactly as entered, although its check digit is invalid).'
          : 'Barcode $cleanBarcode is valid, but no product record was found in the available databases '
              '(cosmetics coverage is incomplete). Search by name, or enter the details manually.'
              '${region != null ? ' (Barcode registered in $region.)' : ''}',
    );
  }

  static AttemptOutcome _outcomeFor(_JsonResponse res) {
    if (res.statusCode == 429) return AttemptOutcome.rateLimited;
    if (res.statusCode >= 500) return AttemptOutcome.serverError;
    if (res.json == null) return AttemptOutcome.malformed;
    // Open*Facts: "not found" is status 0 (HTTP 404, or 200 on older API versions).
    if (res.json!['status'] == 0 || res.statusCode == 404) return AttemptOutcome.notFound;
    return AttemptOutcome.malformed;
  }

  static String _outcomeText(AttemptOutcome o) => switch (o) {
        AttemptOutcome.serverError => 'server error',
        AttemptOutcome.rateLimited => 'too many requests',
        AttemptOutcome.timeout => 'timed out',
        AttemptOutcome.unreachable => 'not reachable',
        AttemptOutcome.malformed => 'unreadable answer',
        AttemptOutcome.rejected => 'record for a different barcode',
        AttemptOutcome.notFound => 'not found',
        AttemptOutcome.found => 'found',
      };

  static const _searchUrl = 'https://world.openbeautyfacts.org/cgi/search.pl';

  /// Searches Open Beauty Facts by product name and/or brand (user-triggered only; the
  /// service allows about 10 searches per minute). Results without a barcode or name are
  /// dropped. Returns candidates for the user to choose from: nothing is auto-selected.
  static Future<ProductSearchResult> searchByName(String query) async {
    final q = query.trim();
    if (q.length < 3) return const ProductSearchResult([], 'Type at least 3 letters of the name or brand.');
    final uri = Uri.parse(_searchUrl).replace(queryParameters: {
      'search_terms': q,
      'search_simple': '1',
      'action': 'process',
      'json': '1',
      'page_size': '15',
      'fields': 'code,product_name,brands,quantity,image_front_small_url',
    });
    try {
      final res = await _getJson(uri, const Duration(seconds: 12));
      if (res.statusCode != 200 || res.json == null) {
        return ProductSearchResult(const [], 'The search did not work (${_outcomeText(_outcomeFor(res))}). Try again later.');
      }
      final products = res.json!['products'];
      if (products is! List) return const ProductSearchResult([], 'The search returned an unreadable answer.');
      final out = <ProductSearchCandidate>[];
      final seen = <String>{};
      for (final p in products.whereType<Map>()) {
        final code = BarcodeUtils.normalize('${p['code'] ?? ''}');
        final name = _text([p['product_name']]);
        if (code == null || name == null || !seen.add(code)) continue;
        out.add(ProductSearchCandidate(
          barcode: code,
          name: name,
          brand: _text([p['brands']]) ?? '',
          quantity: _text([p['quantity']]),
          imageUrl: _text([p['image_front_small_url']]),
        ));
      }
      return ProductSearchResult(out, out.isEmpty ? 'No products matched "$q".' : null);
    } on _Unreachable catch (e) {
      return ProductSearchResult(
        const [],
        e.isTimeout ? 'The search did not answer in time. Try again.' : 'Could not reach Open Beauty Facts (offline?).',
      );
    }
  }

  /// First non-empty trimmed string among [values] (ignores non-strings and blanks).
  static String? _text(Iterable<dynamic> values) {
    for (final v in values) {
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Parses Open Beauty/Food Facts comprehensive JSON
  static ProductModel _parseApiProduct(String barcode, Map<String, dynamic> p, String sourceDb) {
    // 1. Name (empty strings are common in these databases; fall through to the next field).
    // Left empty when the record has no name, so the user fills it in instead of saving a placeholder.
    final name = _text([p['product_name'], p['product_name_en'], p['generic_name'], p['product_name_fr']]) ?? '';

    // 2. Brand
    final brandTags = p['brands_tags'];
    final brand = _text([
          p['brands'],
          p['brand_owner'],
          if (brandTags is List && brandTags.isNotEmpty)
            brandTags.first.toString().replaceAll('en:', '').replaceAll('-', ' '),
        ]) ??
        '';

    // 3. Images
    final imageUrl = p['image_front_url'] as String? ??
        p['image_url'] as String? ??
        p['image_front_small_url'] as String? ??
        (p['selected_images']?['front']?['display']?['en'] as String?);

    final thumbnailUrl = p['image_front_small_url'] as String? ??
        p['image_small_url'] as String? ??
        (p['selected_images']?['front']?['thumb']?['en'] as String?);

    // Collect image gallery from selected_images
    final imageGallery = <String>[];
    final selectedImages = p['selected_images'] as Map<String, dynamic>?;
    if (selectedImages != null) {
      for (final side in ['front', 'ingredients', 'nutrition', 'packaging']) {
        final sideData = selectedImages[side] as Map<String, dynamic>?;
        final displayData = sideData?['display'] as Map<String, dynamic>?;
        if (displayData != null) {
          final url = displayData['en'] as String? ?? displayData.values.firstOrNull?.toString();
          if (url != null && url.isNotEmpty && !imageGallery.contains(url)) {
            imageGallery.add(url);
          }
        }
      }
    }

    // 4. Volume / Quantity
    final volume = (p['quantity'] as String?)?.trim() ??
        (p['product_quantity'] != null ? '${p['product_quantity']} ${p['product_quantity_unit'] ?? ''}'.trim() : null);

    // 5. Ingredients: the record's own list, in the record's language. Empty strings are
    // common and mean "no list".
    final ingredients = _text([p['ingredients_text'], p['ingredients_text_en']]);
    final inci = _text([p['ingredients_text_en']]);
    final soldIn = (p['countries_tags'] is List)
        ? (p['countries_tags'] as List)
            .map((c) => c.toString().replaceFirst(RegExp(r'^[a-z]{2}:'), '').replaceAll('-', ' '))
            .where((c) => c.isNotEmpty)
            .join(', ')
        : '';
    final lastModified = p['last_modified_t'] is num
        ? DateTime.fromMillisecondsSinceEpoch((p['last_modified_t'] as num).toInt() * 1000)
        : null;
    final ingredientsContext = ingredients == null
        ? null
        : [
            '$sourceDb record $barcode',
            if (soldIn.isNotEmpty) 'sold in: $soldIn',
            if (lastModified != null) 'record updated ${lastModified.toIso8601String().split('T').first}',
          ].join('; ');

    // 6. Category & PAO (only a PAO the record explicitly lists counts as product data)
    final categorySuggestion = detectCategory(p);
    final detectedCategory = _findCategory(categorySuggestion?.categoryId ?? 'other');
    final explicitPao = _extractPao(p);
    final paoMonths = explicitPao ?? detectedCategory.defaultPaoMonths;
    // A category default is only an estimate, and without an identified category there is
    // nothing to base one on: PAO stays unknown until the user sets it.
    final paoSource = explicitPao != null
        ? PaoSource.productDatabase
        : (categorySuggestion != null ? PaoSource.categoryDefault : PaoSource.unknown);

    // 7. Country of origin: only where the record states origin or place of manufacture
    // ("countries" in these databases means where the product is sold).
    final country = _extractCountry(p);

    // 8. Packaging type
    final packaging = _extractPackaging(p);

    // 9. Skin Claims & Key Actives
    final claims = _extractClaims(p, name, ingredients);
    final keyActives = _extractKeyActives(ingredients, name);

    // 10. Allergens
    final allergens = _extractAllergens(p, ingredients);

    // 11. Preservatives detected from ingredients
    final preservatives = _extractPreservatives(ingredients);

    // 12. Fragrance ingredients
    final fragranceIngredients = _extractFragranceIngredients(ingredients);

    // 13. Warnings
    final warnings = _extractWarnings(p);

    // 14. Certifications
    final certifications = _extractCertifications(p);

    // 15. Skin type
    final skinType = _extractSkinType(p, name, ingredients);

    // 16. Application area
    final applicationArea = _extractApplicationArea(p, name, detectedCategory.categoryId);

    // 17. Texture
    final texture = _extractTexture(p, name, detectedCategory.categoryId);

    // 18. Scent / Fragrance profile
    final scent = _extractScent(p, name, ingredients);

    // 19. pH level
    final pH = _extractPH(p);

    // 20. Product code / SKU
    final productCode = p['code'] as String? ?? p['_id'] as String?;

    // 21. Product page URL on the database the record came from
    final host = switch (sourceDb) {
      'Open Food Facts' => 'world.openfoodfacts.org',
      'Open Products Facts' => 'world.openproductsfacts.org',
      _ => 'world.openbeautyfacts.org',
    };
    final barcodeScanUrl = _text([p['url']]) ?? 'https://$host/product/$barcode';

    return ProductModel(
      productId: 'prod_${DateTime.now().millisecondsSinceEpoch}_$barcode',
      barcode: barcode,
      name: name,
      brand: brand,
      categoryId: detectedCategory.categoryId,
      categorySource: categorySuggestion?.source ?? CategorySource.unknown,
      paoMonths: paoMonths,
      paoSource: paoSource,
      imageUrl: imageUrl,
      thumbnailUrl: thumbnailUrl,
      volume: volume,
      ingredients: ingredients,
      ingredientsSource: ingredients != null ? IngredientSource.productDatabase : IngredientSource.notRecorded,
      ingredientsUpdatedAt: ingredients != null ? DateTime.now() : null,
      ingredientsContext: ingredientsContext,
      countryOfOrigin: country,
      packagingType: packaging,
      skinClaims: claims,
      keyActives: keyActives,
      sourceDatabase: sourceDb,
      createdAt: DateTime.now(),
      allergens: allergens,
      preservatives: preservatives,
      fragranceIngredients: fragranceIngredients,
      warnings: warnings,
      certifications: certifications,
      skinType: skinType,
      applicationArea: applicationArea,
      texture: texture,
      scent: scent,
      pH: pH,
      inci: inci,
      barcodeScanUrl: barcodeScanUrl,
      productCode: productCode,
      imageGallery: imageGallery,
    );
  }


  /// Parses UPC Item DB API
  static ProductModel _parseUpcDbProduct(String barcode, Map<String, dynamic> item) {
    final title = _text([item['title']]) ?? '';
    final brand = _text([item['brand']]) ?? '';
    final category = (item['category'] as String?) ?? '';
    final images = item['images'] as List?;
    final imageUrl = images != null && images.isNotEmpty ? images[0] as String? : null;

    final suggestion = CategoryClassifier.fromDatabaseCategories(category.split('>')) ?? CategoryClassifier.fromName(title);
    final detectedCat = _findCategory(suggestion?.categoryId ?? 'other');
    final claims = _extractClaimsFromText(title);
    final keyActives = _extractKeyActives(item['description'] as String?, title);

    return ProductModel(
      productId: 'prod_${DateTime.now().millisecondsSinceEpoch}_$barcode',
      barcode: barcode,
      name: title,
      brand: brand,
      categoryId: detectedCat.categoryId,
      categorySource: suggestion?.source ?? CategorySource.unknown,
      paoMonths: detectedCat.defaultPaoMonths,
      paoSource: suggestion != null ? PaoSource.categoryDefault : PaoSource.unknown,
      imageUrl: imageUrl,
      volume: item['size'] as String?,
      skinClaims: claims,
      keyActives: keyActives,
      sourceDatabase: 'UPC Database',
      createdAt: DateTime.now(),
    );
  }

  // ===================== INTELLIGENT METADATA EXTRACTORS =====================

  /// The record's own categories first (most specific tag first), then its name; null
  /// when neither identifies a category.
  static CategorySuggestion? detectCategory(Map<String, dynamic> p) {
    List<String> strings(Object? raw) => raw is List ? raw.map((e) => e.toString()).toList() : const [];
    final hierarchy = strings(p['categories_hierarchy']);
    final tags = hierarchy.isNotEmpty ? hierarchy : strings(p['categories_tags']);
    final free = (p['categories'] as String? ?? '').split(',');
    return CategoryClassifier.fromDatabaseCategories([...free, ...tags]) ??
        CategoryClassifier.fromName('${p['product_name'] ?? ''} ${p['generic_name'] ?? ''}');
  }

  static CategoryModel _findCategory(String id) => CategoryModel.byId(id) ?? CategoryModel.defaultCategories.last;

  /// The PAO the database explicitly lists for this product, or null when it lists none.
  ///
  /// Open Beauty Facts stores it as `periods_after_opening_tags` (e.g. "en:12-months") and
  /// the free-text `periods_after_opening` (e.g. "12 M", "12 mois"); these field names were
  /// checked against live API responses. The app previously read `period_after_opening`,
  /// which does not exist, so every lookup fell back to the category default.
  static int? extractPao(Map<String, dynamic> p) {
    int? valid(String? digits) {
      final n = int.tryParse(digits ?? '');
      return n != null && n >= ProductModel.minPaoMonths && n <= ProductModel.maxPaoMonths ? n : null;
    }

    final tags = p['periods_after_opening_tags'];
    if (tags is List) {
      for (final t in tags) {
        final m = RegExp(r'(\d+)-months?$').firstMatch(t.toString());
        final n = valid(m?.group(1));
        if (n != null) return n;
      }
    }
    final text = _text([p['periods_after_opening'], p['period_after_opening']]);
    if (text != null) {
      final m = RegExp(r'(\d+)\s*(m\b|mois|months?|monate|meses|mesi)', caseSensitive: false).firstMatch(text);
      return valid(m?.group(1));
    }
    return null;
  }

  static int? _extractPao(Map<String, dynamic> p) => extractPao(p);

  static String? _extractCountry(Map<String, dynamic> p) {
    final origin = _text([p['origins'], p['manufacturing_places']]);
    if (origin != null) {
      return origin.split(',').first.trim().replaceFirst(RegExp(r'^[a-z]{2}:'), '');
    }
    // No barcode-prefix guess: a GS1 prefix shows where the barcode was registered,
    // not where the product was made.
    return null;
  }

  static String? _getCountryFromBarcodePrefix(String barcode) {
    if (barcode.length < 3) return null;
    final prefix2 = barcode.substring(0, 2);
    final prefix3 = barcode.substring(0, 3);
    final n2 = int.tryParse(prefix2) ?? -1;
    final n3 = int.tryParse(prefix3) ?? -1;

    if (n2 >= 0 && n2 <= 13) return 'United States / Canada';
    if (n2 >= 30 && n2 <= 37) return 'France';
    if (n2 >= 40 && n2 <= 44) return 'Germany';
    if (n3 == 450 || n3 == 490 || (n3 >= 450 && n3 <= 459) || (n3 >= 490 && n3 <= 499)) return 'Japan';
    if (n2 == 50) return 'United Kingdom';
    if (n2 >= 80 && n2 <= 83) return 'Italy';
    if (n2 == 84) return 'Spain';
    if (n3 == 880) return 'South Korea';
    if (n3 == 890) return 'India';
    if (n3 >= 690 && n3 <= 699) return 'China';
    if (n2 == 93) return 'Australia';
    if (n2 == 76) return 'Switzerland';
    return null;
  }

  static String? _extractPackaging(Map<String, dynamic> p) {
    final packStr = [
      p['packaging'] ?? '',
      p['packaging_text'] ?? '',
      p['packaging_tags'] != null ? (p['packaging_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (packStr.contains('dropper') || packStr.contains('pipette')) return 'Dropper Pipette';
    if (packStr.contains('pump') || packStr.contains('dispenser')) return 'Pump Bottle';
    if (packStr.contains('tube') || packStr.contains('squeeze')) return 'Squeeze Tube';
    if (packStr.contains('jar') || packStr.contains('pot') || packStr.contains('tub')) return 'Jar / Tub';
    if (packStr.contains('spray') || packStr.contains('mist') || packStr.contains('aerosol')) return 'Spray Mist';
    if (packStr.contains('stick') || packStr.contains('roll-on')) return 'Stick Applicator';
    if (packStr.contains('bottle') || packStr.contains('flacon')) return 'Bottle';
    return null;
  }

  static List<String> _extractClaims(Map<String, dynamic> p, String name, String? ingredients) {
    final claims = <String>{};
    final combined = [
      name,
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
      ingredients ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('fragrance-free') || combined.contains('sans parfum') || combined.contains('unscented')) {
      claims.add('Fragrance-Free');
    }
    if (combined.contains('non-comedogenic') || combined.contains('non comedogene')) {
      claims.add('Non-Comedogenic');
    }
    if (combined.contains('paraben-free') || combined.contains('sans paraben')) {
      claims.add('Paraben-Free');
    }
    if (combined.contains('cruelty-free') || combined.contains('vegan') || combined.contains('leaping bunny')) {
      claims.add('Cruelty-Free / Vegan');
    }
    if (combined.contains('spf') || combined.contains('pa++++') || combined.contains('broad spectrum')) {
      claims.add('SPF Protection');
    }
    if (combined.contains('dermatologist tested') || combined.contains('dermatologically tested')) {
      claims.add('Dermatologist Tested');
    }
    if (combined.contains('hypoallergenic') || combined.contains('sensitive skin')) {
      claims.add('For Sensitive Skin');
    }
    if (combined.contains('alcohol-free') || combined.contains('sans alcool')) {
      claims.add('Alcohol-Free');
    }
    if (combined.contains('hydrating') || combined.contains('moisturizing')) {
      claims.add('Deep Hydration');
    }

    return claims.toList();
  }

  static List<String> _extractClaimsFromText(String text) {
    final claims = <String>[];
    final lower = text.toLowerCase();
    if (lower.contains('spf')) claims.add('SPF Protection');
    if (lower.contains('hydrating') || lower.contains('hyaluronic')) claims.add('Hydrating');
    if (lower.contains('soothing') || lower.contains('calming') || lower.contains('cica')) claims.add('Soothing');
    if (lower.contains('brightening') || lower.contains('vitamin c')) claims.add('Brightening');
    if (lower.contains('anti-aging') || lower.contains('retinol')) claims.add('Anti-Aging');
    return claims;
  }

  static String? _extractKeyActives(String? ingredients, String name) {
    if (ingredients == null && name.isEmpty) return null;
    final text = '${name.toLowerCase()} ${ingredients?.toLowerCase() ?? ''}';
    final actives = <String>[];

    if (text.contains('hyaluronic acid') || text.contains('sodium hyaluronate')) actives.add('Hyaluronic Acid');
    if (text.contains('niacinamide')) actives.add('Niacinamide (Vitamin B3)');
    if (text.contains('ceramide') || text.contains('ceramides')) actives.add('Ceramides NP/AP/EOP');
    if (text.contains('centella asiatica') || text.contains('madecassoside') || text.contains('cica')) actives.add('Centella Asiatica (Cica)');
    if (text.contains('salicylic acid') || RegExp(r'\bbha\b').hasMatch(text)) actives.add('Salicylic Acid (BHA)');
    if (text.contains('glycolic acid') || text.contains('lactic acid') || RegExp(r'\baha\b').hasMatch(text)) {
      actives.add('AHA (Glycolic / Lactic Acid)');
    }
    if (text.contains('ascorbic acid') || text.contains('vitamin c')) actives.add('Vitamin C');
    if (text.contains('retinol') || RegExp(r'\bretinal\b').hasMatch(text)) actives.add('Retinol / Retinal');
    if (text.contains('bakuchiol')) actives.add('Bakuchiol');
    if (text.contains('snail secretion') || text.contains('snail mucin')) actives.add('Snail Secretion Filtrate');
    if (text.contains('panthenol') || text.contains('vitamin b5')) actives.add('Panthenol (Pro-Vitamin B5)');
    if (text.contains('zinc pca') || text.contains('zinc oxide')) actives.add('Zinc');
    if (text.contains('propolis') || text.contains('honey')) actives.add('Propolis Extract');
    if (text.contains('peptide') || text.contains('peptides')) actives.add('Peptides Complex');
    if (text.contains('squalane')) actives.add('Plant-derived Squalane');
    if (text.contains('tea tree') || text.contains('melaleuca')) actives.add('Tea Tree');

    return actives.isNotEmpty ? actives.join(' • ') : null;
  }

  static String? _extractAllergens(Map<String, dynamic> p, String? ingredients) {
    final raw = (p['allergens'] as String?)?.trim() ??
        (p['allergens_from_ingredients'] as String?)?.trim();

    if (raw != null && raw.isNotEmpty) {
      return raw.replaceAll('en:', '').replaceAll(',', ', ').trim();
    }

    // Infer from ingredients if labeled in INCI
    if (ingredients != null) {
      final lower = ingredients.toLowerCase();
      final found = <String>[];
      if (lower.contains('parfum') || lower.contains('fragrance')) found.add('Fragrance (Parfum)');
      if (lower.contains('limonene')) found.add('Limonene');
      if (lower.contains('linalool')) found.add('Linalool');
      if (lower.contains('citronellol')) found.add('Citronellol');
      if (lower.contains('geraniol')) found.add('Geraniol');
      if (lower.contains('benzyl alcohol')) found.add('Benzyl Alcohol');
      if (lower.contains('eugenol')) found.add('Eugenol');
      if (lower.contains('cinnamal')) found.add('Cinnamal');
      if (lower.contains('coumarin')) found.add('Coumarin');
      if (lower.contains('isoeugenol')) found.add('Isoeugenol');
      if (found.isNotEmpty) return found.join(', ');
    }
    return null;
  }

  static String? _extractPreservatives(String? ingredients) {
    if (ingredients == null) return null;
    final lower = ingredients.toLowerCase();
    final found = <String>[];

    if (lower.contains('phenoxyethanol')) found.add('Phenoxyethanol');
    if (lower.contains('ethylhexylglycerin')) found.add('Ethylhexylglycerin');
    if (lower.contains('caprylyl glycol')) found.add('Caprylyl Glycol');
    if (lower.contains('sodium benzoate')) found.add('Sodium Benzoate');
    if (lower.contains('potassium sorbate')) found.add('Potassium Sorbate');
    if (lower.contains('methylparaben') || lower.contains('propylparaben') ||
        lower.contains('butylparaben') || lower.contains('ethylparaben')) {
      found.add('Parabens');
    }
    if (lower.contains('benzalkonium chloride')) found.add('Benzalkonium Chloride');
    if (lower.contains('chlorphenesin')) found.add('Chlorphenesin');
    if (lower.contains('dehydroacetic acid')) found.add('Dehydroacetic Acid');
    if (lower.contains('1,2-hexanediol') || lower.contains('1,2 hexanediol')) found.add('1,2-Hexanediol');

    return found.isNotEmpty ? found.join(', ') : null;
  }

  static String? _extractFragranceIngredients(String? ingredients) {
    if (ingredients == null) return null;
    final lower = ingredients.toLowerCase();
    final found = <String>[];

    if (lower.contains('parfum') || lower.contains('fragrance')) found.add('Parfum/Fragrance');
    if (lower.contains('limonene')) found.add('Limonene');
    if (lower.contains('linalool')) found.add('Linalool');
    if (lower.contains('citronellol')) found.add('Citronellol');
    if (lower.contains('geraniol')) found.add('Geraniol');
    if (lower.contains('citral')) found.add('Citral');
    if (lower.contains('eugenol')) found.add('Eugenol');
    if (lower.contains('cinnamal')) found.add('Cinnamal');
    if (lower.contains('benzyl salicylate')) found.add('Benzyl Salicylate');
    if (lower.contains('alpha-isomethyl ionone')) found.add('Alpha-Isomethyl Ionone');

    return found.isNotEmpty ? found.join(', ') : null;
  }

  static List<String> _extractWarnings(Map<String, dynamic> p) {
    final warnings = <String>[];
    final combined = [
      p['warning'] ?? '',
      p['conservation_conditions'] ?? '',
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (combined.contains('avoid eye')) warnings.add('Avoid contact with eyes');
    if (combined.contains('keep out of reach')) warnings.add('Keep out of reach of children');
    if (combined.contains('flammable') || combined.contains('inflammable')) warnings.add('Flammable');
    if (combined.contains('do not swallow') || combined.contains('not for ingestion')) warnings.add('Not for ingestion');
    if (combined.contains('patch test') || combined.contains('sensitivity test')) warnings.add('Patch test recommended');
    if (combined.contains('discontinue use')) warnings.add('Discontinue if irritation occurs');
    if (combined.contains('not suitable for children')) warnings.add('Not suitable for children');
    if (combined.contains('consult a doctor') || combined.contains('consult physician')) warnings.add('Consult a physician before use');
    if (combined.contains('pregnancy') || combined.contains('pregnant')) warnings.add('Consult doctor if pregnant or nursing');

    return warnings;
  }

  static List<String> _extractCertifications(Map<String, dynamic> p) {
    final certs = <String>[];
    final labelsStr = [
      p['labels'] ?? '',
      p['labels_tags'] != null ? (p['labels_tags'] as List).join(' ') : '',
    ].join(' ').toLowerCase();

    if (labelsStr.contains('ecocert') || labelsStr.contains('ecocert')) certs.add('Ecocert Certified');
    if (labelsStr.contains('cosmos organic') || labelsStr.contains('cosmos-organic')) certs.add('COSMOS Organic');
    if (labelsStr.contains('cosmos natural')) certs.add('COSMOS Natural');
    if (labelsStr.contains('natrue')) certs.add('NATRUE Certified');
    if (labelsStr.contains('usda organic') || labelsStr.contains('usda-organic')) certs.add('USDA Organic');
    if (labelsStr.contains('leaping bunny')) certs.add('Leaping Bunny (Cruelty-Free)');
    if (labelsStr.contains('peta') || labelsStr.contains('certified vegan')) certs.add('PETA Certified');
    if (labelsStr.contains('fragrance free') || labelsStr.contains('fragrance-free')) certs.add('Fragrance-Free');
    if (labelsStr.contains('dermatologist tested')) certs.add('Dermatologist Tested');
    if (labelsStr.contains('allergy tested') || labelsStr.contains('hypoallergenic')) certs.add('Hypoallergenic');
    if (labelsStr.contains('non-comedogenic') || labelsStr.contains('non comedogenic')) certs.add('Non-Comedogenic');
    if (labelsStr.contains('ophthalmologist')) certs.add('Ophthalmologist Tested');
    if (labelsStr.contains('iso ') && (labelsStr.contains('22716') || labelsStr.contains('9001'))) certs.add('ISO Certified');

    return certs;
  }

  static String? _extractSkinType(Map<String, dynamic> p, String name, String? ingredients) {
    final combined = [
      name,
      p['product_name'] ?? '',
      p['generic_name'] ?? '',
      p['labels'] ?? '',
      ingredients ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('oily skin') || combined.contains('oil-free') || combined.contains('for oily')) return 'Oily Skin';
    if (combined.contains('dry skin') || combined.contains('for dry') || combined.contains('very dry')) return 'Dry Skin';
    if (combined.contains('combination skin') || combined.contains('for combination')) return 'Combination Skin';
    if (combined.contains('sensitive skin') || combined.contains('for sensitive') || combined.contains('hypoallergenic')) return 'Sensitive Skin';
    if (combined.contains('normal skin') || combined.contains('all skin types') || combined.contains('tous types')) return 'All Skin Types';
    if (combined.contains('mature skin') || combined.contains('anti-aging') || combined.contains('anti-age')) return 'Mature Skin';
    if (combined.contains('acne') || combined.contains('blemish') || combined.contains('acne-prone')) return 'Acne-Prone Skin';
    return null;
  }

  static String? _extractApplicationArea(Map<String, dynamic> p, String name, String categoryId) {
    final combined = [
      name,
      p['generic_name'] ?? '',
      p['categories'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('eye') || categoryId == 'eye_cream' || categoryId == 'mascara') return 'Eye Area';
    if (combined.contains('lip') || categoryId == 'lipstick') return 'Lips';
    if (combined.contains('body') || combined.contains('hands') || combined.contains('foot')) return 'Body';
    if (combined.contains('hair') || combined.contains('scalp')) return 'Hair & Scalp';
    if (combined.contains('neck') || combined.contains('décolleté') || combined.contains('decollete')) return 'Face, Neck & Décolleté';
    if (combined.contains('face') || combined.contains('facial') || combined.contains('visage')) return 'Face';
    return null; // not stated: left empty rather than assumed
  }

  static String? _extractTexture(Map<String, dynamic> p, String name, String categoryId) {
    final combined = [
      name,
      p['generic_name'] ?? '',
      p['categories'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('gel') || combined.contains('jelly')) return 'Gel';
    if (combined.contains('foam') || combined.contains('mousse')) return 'Foam / Mousse';
    if (combined.contains('oil') && !combined.contains('oil-free')) return 'Oil / Dry Oil';
    if (combined.contains('milk') || combined.contains('emulsion')) return 'Fluid / Emulsion';
    if (combined.contains('balm') || combined.contains('baume')) return 'Balm / Ointment';
    if (combined.contains('mist') || combined.contains('spray') || combined.contains('toner')) return 'Watery Mist / Toner';
    if (combined.contains('serum') || combined.contains('ampoule') || combined.contains('essence')) return 'Lightweight Serum';
    if (combined.contains('cream') || combined.contains('crème') || categoryId == 'moisturizer') return 'Cream';
    if (combined.contains('lotion')) return 'Lotion';
    if (combined.contains('powder') || combined.contains('poudre')) return 'Powder';
    if (combined.contains('stick') || combined.contains('baton')) return 'Solid Stick';
    return null;
  }

  static String? _extractScent(Map<String, dynamic> p, String name, String? ingredients) {
    final combined = [
      name,
      p['product_name'] ?? '',
      p['generic_name'] ?? '',
    ].join(' ').toLowerCase();

    if (combined.contains('unscented') || combined.contains('fragrance-free') || combined.contains('sans parfum')) return 'Fragrance-Free / Unscented';
    if (combined.contains('rose') || combined.contains('floral')) return 'Floral (Rose)';
    if (combined.contains('citrus') || combined.contains('orange') || combined.contains('bergamot')) return 'Citrus';
    if (combined.contains('lavender') || combined.contains('lavande')) return 'Floral (Lavender)';
    if (combined.contains('vanilla')) return 'Warm / Vanilla';
    if (combined.contains('mint') || combined.contains('menthol')) return 'Fresh / Minty';
    if (combined.contains('cedar') || combined.contains('woody') || combined.contains('sandalwood')) return 'Woody / Earthy';
    if (combined.contains('musk')) return 'Musky';
    if (combined.contains('berry') || combined.contains('fruit')) return 'Fruity / Berry';
    if (combined.contains('fresh') || combined.contains('aqua')) return 'Fresh / Aquatic';
    // Not inferred from an ingredient list without "parfum": that is not a fragrance-free claim.
    return null;
  }

  /// Only a pH the record states; never guessed from the product name.
  static String? _extractPH(Map<String, dynamic> p) {
    final phRaw = _text([p['ph'], p['pH']]);
    return phRaw != null ? 'pH $phRaw' : null;
  }

  // ===================== CURATED BEAUTY INTELLIGENCE LOCAL CATALOG =====================


  /// Offline fallback only. Entries were written into the app and are not verified: a
  /// barcode whose check digit is invalid cannot be a real product, and one entry
  /// (3337875597180) was shown by Open Beauty Facts to belong to a different product, so
  /// it was removed. PAO and ingredients are labelled as catalog data.
  static ProductModel? _lookupLocalCatalog(String barcode) {
    if (!BarcodeUtils.hasValidCheckDigit(barcode)) return null;
    final entry = _curatedBeautyCatalog[barcode];
    if (entry == null) return null;
    return entry.copyWith(
      paoSource: PaoSource.appCatalog,
      ingredientsSource: entry.ingredients != null ? IngredientSource.appCatalog : null,
    );
  }

  // Offline fallback only (labelled unverified). Nine entries were removed on 2026-10-19
  // because their barcodes had impossible GS1 check digits (e.g. 8809643068098), so they
  // could not belong to any real product; every remaining key passes validation (tested).
  @visibleForTesting
  static Iterable<String> get catalogBarcodes => _curatedBeautyCatalog.keys;

  static final Map<String, ProductModel> _curatedBeautyCatalog = {
    // La Roche-Posay ("3337875597180" removed: Open Beauty Facts lists that barcode as
    // CeraVe Hydrating Cleanser, not Hyalu B5.)
    '3337875545778': const ProductModel(
      productId: 'curated_lrp_anthelios',
      barcode: '3337875545778',
      name: 'Anthelios UVMune 400 Invisible Fluid SPF50+',
      brand: 'La Roche-Posay',
      categoryId: 'sunscreen',
      paoMonths: 12,
      volume: '50 ml',
      countryOfOrigin: 'France',
      packagingType: 'Bottle',
      skinClaims: ['SPF Protection', 'Fragrance-Free', 'Non-Comedogenic'],
      keyActives: 'Mexoryl 400 • Netlock Technology • Vitamin E',
      ingredients: 'Aqua / Water, Alcohol Denat., Triethyl Citrate, Diisopropyl Sebacate, Silica, Ethylhexyl Salicylate, Bis-Ethylhexyloxyphenol Methoxyphenyl Triazine, Ethylhexyl Triazone, Butyl Methoxydibenzoylmethane, Glycerin, Propanediol, C12-22 Alkyl Acrylate/Hydroxyethylacrylate Copolymer, Methoxypropylamino Cyclohexenylidene Ethoxyethylcyanoacetate, Perlite, Drometrizole Trisiloxane, Caprylic/Capric Triglyceride, Tocopherol...',
    ),
    '3337875597388': const ProductModel(
      productId: 'curated_cerave_hydrating_cleanser',
      barcode: '3337875597388',
      name: 'Hydrating Facial Cleanser for Normal to Dry Skin',
      brand: 'CeraVe',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '236 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Pump Bottle',
      skinClaims: ['Fragrance-Free', 'Non-Comedogenic', 'Dermatologist Tested'],
      keyActives: 'Ceramides NP/AP/EOP • Hyaluronic Acid',
    ),

    // The Ordinary
    '769915190601': const ProductModel(
      productId: 'curated_the_ordinary_niacinamide',
      barcode: '769915190601',
      name: 'Niacinamide 10% + Zinc 1% High-Strength Vitamin and Mineral Formula',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Alcohol-Free', 'Cruelty-Free / Vegan', 'Fragrance-Free'],
      keyActives: 'Niacinamide (Vitamin B3) • Zinc',
      ingredients: 'Aqua (Water), Niacinamide, Pentylene Glycol, Zinc PCA, Dimethyl Isosorbide, Tamarindus Indica Seed Gum, Xanthan Gum, Isoceteth-20, Ethoxydiglycol, Phenoxyethanol, Chlorphenesin.',
    ),
    '769915190588': const ProductModel(
      productId: 'curated_the_ordinary_ha',
      barcode: '769915190588',
      name: 'Hyaluronic Acid 2% + B5 Hydration Support Formula',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Deep Hydration', 'Cruelty-Free / Vegan', 'Fragrance-Free'],
      keyActives: 'Hyaluronic Acid • Panthenol (Pro-Vitamin B5)',
    ),
    '769915190595': const ProductModel(
      productId: 'curated_the_ordinary_aha_bha',
      barcode: '769915190595',
      name: 'AHA 30% + BHA 2% Peeling Solution (10-Minute Exfoliating Facial)',
      brand: 'The Ordinary',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '30 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Dropper Pipette',
      skinClaims: ['Cruelty-Free / Vegan', 'Alcohol-Free'],
      keyActives: 'AHA (Glycolic / Lactic Acid) • Salicylic Acid (BHA) • Hyaluronic Acid',
    ),

    // COSRX
    '8809416470009': const ProductModel(
      productId: 'curated_cosrx_snail_essence',
      barcode: '8809416470009',
      name: 'Advanced Snail 96 Mucin Power Essence',
      brand: 'COSRX',
      categoryId: 'serum',
      paoMonths: 12,
      volume: '100 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Pump Bottle',
      skinClaims: ['Fragrance-Free', 'Cruelty-Free / Vegan', 'Deep Hydration', 'For Sensitive Skin'],
      keyActives: 'Snail Secretion Filtrate (96%) • Sodium Hyaluronate • Panthenol (Pro-Vitamin B5) • Allantoin',
      ingredients: 'Snail Secretion Filtrate, Betaine, Butylene Glycol, 1,2-Hexanediol, Sodium Polyacrylate, Phenoxyethanol, Sodium Hyaluronate, Allantoin, Ethyl Hexanediol, Carbomer, Panthenol, Arginine.',
    ),
    '8809416470030': const ProductModel(
      productId: 'curated_cosrx_low_ph',
      barcode: '8809416470030',
      name: 'Low pH Good Morning Gel Cleanser',
      brand: 'COSRX',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '150 ml',
      countryOfOrigin: 'South Korea',
      packagingType: 'Squeeze Tube',
      skinClaims: ['For Sensitive Skin', 'Cruelty-Free / Vegan'],
      keyActives: 'Tea Tree • Betaine Salicylate (BHA)',
    ),

    // Paula's Choice
    '041554420616': const ProductModel(
      productId: 'curated_maybelline_sky_high',
      barcode: '041554420616',
      name: 'Lash Sensational Sky High Washable Mascara (Very Black)',
      brand: 'Maybelline New York',
      categoryId: 'mascara',
      paoMonths: 3,
      volume: '7.2 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Stick Applicator',
      skinClaims: ['Ophthalmologist Tested', 'For Sensitive Eyes'],
      keyActives: 'Bamboo Extract • Fiber Extensions',
    ),
    '041554422504': const ProductModel(
      productId: 'curated_maybelline_instant_age_rewind',
      barcode: '041554422504',
      name: 'Instant Age Rewind Multi-Use Concealer',
      brand: 'Maybelline New York',
      categoryId: 'foundation',
      paoMonths: 6,
      volume: '6.0 ml',
      countryOfOrigin: 'United States / Canada',
      packagingType: 'Stick Applicator',
      keyActives: 'Haloxyl • Goji Berry Extract',
    ),

    // Laneige
    '3401575645851': const ProductModel(
      productId: 'curated_bioderma_sensibio',
      barcode: '3401575645851',
      name: 'Sensibio H2O Soothing Micellar Water',
      brand: 'Bioderma',
      categoryId: 'cleanser',
      paoMonths: 12,
      volume: '500 ml',
      countryOfOrigin: 'France',
      packagingType: 'Bottle',
      skinClaims: ['Fragrance-Free', 'Alcohol-Free', 'For Sensitive Skin', 'Dermatologist Tested'],
      keyActives: 'Micellar Technology • Cucumis Sativus (Cucumber) Fruit Extract',
    ),

    // Minimalist
  };
}
