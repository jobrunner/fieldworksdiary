import Foundation

/// The eight editable placemark fields the manual-override endpoint
/// accepts (Spec §6.2 / backend `manualPlacemarkRequest`). `country`
/// is the only required one — an ISO 3166-1 alpha-2 code.
struct PlacemarkOverrideFields: Equatable {
    var country: String
    var administrativeArea: String = ""
    var subAdministrativeArea: String = ""
    var locality: String = ""
    var subLocality: String = ""
    var postalCode: String = ""
    var name: String = ""
    var thoroughfare: String = ""

    /// The JSON body keyed exactly as the backend expects. `country`
    /// is upper-cased here so the UI doesn't have to.
    var wireBody: [String: Any] {
        [
            "country": country.trimmingCharacters(in: .whitespaces).uppercased(),
            "administrative_area": administrativeArea,
            "sub_administrative_area": subAdministrativeArea,
            "locality": locality,
            "sub_locality": subLocality,
            "postal_code": postalCode,
            "name": name,
            "thoroughfare": thoroughfare
        ]
    }

    /// Pre-fill the form from an already-cached placemark so the user
    /// edits the current values instead of a blank sheet.
    init(from pm: LocalPlacemark) {
        country = pm.country
        administrativeArea = pm.administrativeArea ?? ""
        subAdministrativeArea = pm.subAdministrativeArea ?? ""
        locality = pm.locality ?? ""
        subLocality = pm.subLocality ?? ""
        postalCode = pm.postalCode ?? ""
        name = pm.name ?? ""
        thoroughfare = pm.thoroughfare ?? ""
    }

    init(country: String = "") {
        self.country = country
    }
}

/// Pull-and-override client for `placemarks`.
///
/// The collection is read-allowed for any authenticated user (Spec
/// §6.1 — Placemark is a reference table, not owner-scoped). Writes
/// go through the dedicated `/api/localities/:id/placemark`
/// endpoints, which carry their own authorisation (only the
/// locality's owner may set or clear an override).
struct PlacemarkClient {
    let endpoint: String
    let auth: AuthSession?

    init(endpoint: String, auth: AuthSession? = nil) {
        self.endpoint = endpoint
        self.auth = auth
    }

    /// GET a single placemark by id. Used by Locality detail views
    /// when the locally cached row is missing (first ever view of
    /// the locality on this device).
    func fetch(id: String) async throws -> Placemark {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/collections/placemarks/records/\(id)")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(Placemark.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// PATCH `/api/localities/:id/placemark` — set (or replace) the
    /// manual override. The server looks-up-or-creates a placemark
    /// with `geocoding_source = "manual"`, attaches it to the
    /// locality, and returns the full placemark record so the caller
    /// can write it straight through to the local cache.
    func setManual(localityID: String, fields: PlacemarkOverrideFields) async throws -> Placemark {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/localities/\(localityID)/placemark")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields.wireBody)
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.fieldworks.decode(Placemark.self, from: data)
        } catch {
            throw SampleClientError.decoding(error.localizedDescription)
        }
    }

    /// DELETE `/api/localities/:id/placemark/override` — drop the
    /// manual lock by detaching the placemark. The locality's next
    /// auto-geocode tick repopulates it. Returns nothing; the caller
    /// re-fetches the (now possibly empty) placemark relation.
    func clearOverride(localityID: String) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SampleClientError.noEndpoint }
        guard let url = URL(string: trimmed.appending("/api/localities/\(localityID)/placemark/override")) else {
            throw SampleClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 6
        request.authenticate(with: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else {
            throw SampleClientError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
