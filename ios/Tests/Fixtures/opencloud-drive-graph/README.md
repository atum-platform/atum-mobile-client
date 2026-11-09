# OpenCloud Graph response-shape fixtures

Synthetic values in the public OpenCloud 7.2 / LibreGraph response shapes used
by the Stage A phone client. Sources inspected 2026-10-25:

- https://docs.opencloud.eu/docs/dev/server/apis/http/graph/spaces/
- https://github.com/opencloud-eu/libre-graph-api/blob/main/api/openapi-spec/v1.0.yaml
- https://github.com/opencloud-eu/libre-graph-api-go

The drive fixture retains the documented `owner`, `quota` and `root` fields.
The children fixtures retain `parentReference`, `eTag`, file/folder facets,
WebDAV URLs and nanosecond timestamps. They are response-shape fixtures, not a
recording from Atum production. A redacted live current-provider sample is
still owed before release acceptance.
