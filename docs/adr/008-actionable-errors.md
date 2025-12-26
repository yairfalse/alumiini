# ADR-008: Actionable Error Messages

**Status:** Proposed
**Date:** 2025-12-25

---

## Context

Generic error messages are the enemy of DX:

```
Error: failed to apply resource
Error: sync failed
Error: git operation failed
```

These tell you WHAT failed but not WHY or HOW TO FIX.

Every error in NOPEA should answer three questions:
1. **What** happened?
2. **Why** did it happen?
3. **How** do I fix it?

---

## Decision

**Implement structured error types with suggestions and documentation links.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    ERROR MESSAGE FORMULA                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Error: [What failed]                                          │
│                                                                 │
│   Reason: [Why it failed - root cause]                          │
│                                                                 │
│   Resource: [Which resource/file/repo]                          │
│                                                                 │
│   Suggestion:                                                    │
│     [Actionable steps to fix]                                   │
│                                                                 │
│   Docs: https://nopea.io/errors/[ERROR_CODE]                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Error Catalog

### Git Errors

#### NOPEA-G001: Authentication Failed

```
Error: Git authentication failed

Reason: SSH key not found or invalid for repository

Repository: git@github.com:myorg/private-repo.git

Suggestion:
  1. Verify SSH secret exists:
     kubectl get secret nopea-ssh-keys -n nopea-system

  2. Check key has access to repository:
     ssh -T git@github.com

  3. Ensure secret is mounted correctly in deployment

Docs: https://nopea.io/errors/G001
```

#### NOPEA-G002: Repository Not Found

```
Error: Git repository not found

Reason: Repository does not exist or URL is incorrect

Repository: https://github.com/myorg/doesnt-exist.git

Suggestion:
  1. Verify the repository URL is correct
  2. Check if repository is private (needs authentication)
  3. Ensure the repository hasn't been renamed or deleted

Docs: https://nopea.io/errors/G002
```

#### NOPEA-G003: Branch Not Found

```
Error: Git branch not found

Reason: Branch 'develop' does not exist in repository

Repository: my-app
Branch: develop

Suggestion:
  1. List available branches:
     git ls-remote --heads https://github.com/myorg/my-app.git

  2. Update GitRepository to use correct branch:
     kubectl patch gr my-app --type merge -p '{"spec":{"branch":"main"}}'

Docs: https://nopea.io/errors/G003
```

### Kubernetes Errors

#### NOPEA-K001: Invalid YAML

```
Error: Invalid YAML in manifest

Reason: YAML parsing failed at line 42

File: deploy/configmap.yaml
Line: 42
Detail: found character that cannot start any token

Suggestion:
  1. Check for tab characters (use spaces only)
  2. Validate YAML syntax:
     yamllint deploy/configmap.yaml

  3. Common issues:
     - Missing quotes around special characters
     - Incorrect indentation
     - Tab characters instead of spaces

Docs: https://nopea.io/errors/K001
```

#### NOPEA-K002: Immutable Field

```
Error: Cannot update immutable field

Reason: Field 'spec.clusterIP' is immutable after Service creation

Resource: Service/api-service
Namespace: default
Field: spec.clusterIP

Suggestion:
  1. Delete and recreate the resource:
     kubectl delete svc/api-service -n default
     kubectl nopea sync my-app

  2. Or remove the immutable field from your manifest
     (let Kubernetes assign it automatically)

Docs: https://nopea.io/errors/K002
```

#### NOPEA-K003: Resource Conflict

```
Error: Resource managed by another controller

Reason: Deployment/api has annotation
        'meta.helm.sh/release-name: api-chart'

Resource: Deployment/api
Namespace: default
Owner: Helm release 'api-chart'

Suggestion:
  1. Remove the resource from Helm management:
     helm uninstall api-chart

  2. Or exclude this resource from NOPEA:
     Add annotation: nopea.io/ignore=true

  3. Or use a different namespace to avoid conflict

Docs: https://nopea.io/errors/K003
```

#### NOPEA-K004: Insufficient Permissions

```
Error: Insufficient permissions to apply resource

Reason: ServiceAccount 'nopea-controller' cannot create
        ClusterRole resources

Resource: ClusterRole/admin-role
Verb: create
API Group: rbac.authorization.k8s.io

Suggestion:
  1. If you need ClusterRole management, enable it in values.yaml:
     rbac:
       manageClusterRoles: true

  2. Or exclude ClusterRoles from your repository

  3. Check RBAC configuration:
     kubectl auth can-i create clusterrole --as=system:serviceaccount:nopea-system:nopea-controller

Docs: https://nopea.io/errors/K004
```

#### NOPEA-K005: Image Pull Failed

```
Error: Container image pull failed

Reason: Image 'myregistry.io/app:v1.2.3' not found

Resource: Deployment/api
Container: api
Image: myregistry.io/app:v1.2.3

Suggestion:
  1. Verify image exists:
     docker pull myregistry.io/app:v1.2.3

  2. Check imagePullSecrets are configured:
     kubectl get secret regcred -n default

  3. Verify image tag is correct (not a typo)

Docs: https://nopea.io/errors/K005
```

### Drift Errors

#### NOPEA-D001: Conflict Detected

```
Warning: Conflict between git and cluster state

Reason: Both git commit and manual kubectl changes modified
        the same resource

Resource: ConfigMap/api-config
Namespace: default

Git change: data.TIMEOUT: "30" → "45"
Cluster change: data.TIMEOUT: "30" → "60"

Suggestion:
  1. Review changes and decide which to keep

  2. To keep git version (recommended):
     kubectl nopea sync my-app

  3. To keep cluster version:
     a. Update git with cluster value
     b. Push to repository
     c. Sync will reconcile automatically

  4. To pause healing while you decide:
     kubectl nopea suspend my-app/ConfigMap/api-config

Docs: https://nopea.io/errors/D001
```

---

## Implementation

### Error Type Structure

```elixir
defmodule Nopea.Error do
  @type t :: %__MODULE__{
    code: String.t(),          # "NOPEA-K001"
    message: String.t(),       # Short description
    reason: String.t(),        # Root cause
    resource: String.t(),      # Affected resource
    details: map(),            # Additional context
    suggestions: [String.t()], # Fix steps
    docs_url: String.t()       # Documentation link
  }

  defstruct [:code, :message, :reason, :resource,
             :details, :suggestions, :docs_url]
end
```

### Error Registry

```elixir
defmodule Nopea.Errors do
  @errors %{
    "G001" => %{
      message: "Git authentication failed",
      category: :git,
      suggestions: [...]
    },
    "K001" => %{
      message: "Invalid YAML in manifest",
      category: :kubernetes,
      suggestions: [...]
    }
    # ...
  }

  def build(code, context) do
    template = Map.fetch!(@errors, code)
    %Nopea.Error{
      code: "NOPEA-#{code}",
      message: template.message,
      suggestions: render_suggestions(template.suggestions, context),
      docs_url: "https://nopea.io/errors/#{code}"
    }
  end
end
```

### Logging Format

```elixir
Logger.error("""
Error: #{error.message}

Reason: #{error.reason}

Resource: #{error.resource}

Suggestion:
#{format_suggestions(error.suggestions)}

Docs: #{error.docs_url}
""")
```

---

## Success Criteria

1. Every error has a unique code (NOPEA-XXXX)
2. Every error includes at least one actionable suggestion
3. Every error links to documentation
4. Error messages render correctly in:
   - Controller logs
   - CRD status conditions
   - kubectl-nopea output
   - Kubernetes events

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Structured errors (chosen)** | Consistent, actionable | More work upfront |
| **Plain strings** | Simple | Not actionable |
| **Error codes only** | Short | Requires doc lookup |