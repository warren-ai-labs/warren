# Warren Terminal Workspace

Warren keeps durable terminal runtimes separate from the client views used to access them.

## Language

**Workspace**:
A named working-directory context belonging to a Project, in which Warren
Terminal Sessions run. The project's main checkout is represented as the root
Workspace; linked Git worktrees are additional Workspaces. A Workspace has a
stable identity, an editable display name, a filesystem path, and a checked-out
Git branch. The display name and branch name are independent fields.

**Embedded Editor**:
A code-server-backed editing surface scoped to one Workspace and hosted by a
Warren Client. It is a client integration, not a Warren Terminal Session or a
Host-owned execution resource.
_Avoid_: Editor Session, IDE Session

**Editor Sidebar**:
A client-local trailing rail that exposes the Embedded Editor's Explorer for the
selected Workspace. It is distinct from Warren's resource sidebar and does not
own files.

**Editor Document Pane**:
A client-local surface that displays a file selected from the Editor Sidebar and
can appear beside terminal content. It is not a Warren Terminal Session or a
Host pane.

**Workspace Editor State**:
The client-local durable fact that a Workspace has been opened in the Embedded
Editor, together with optional last-document context. It can make a Workspace
active even when no Warren Terminal Session is running.

**Active Workspace**:
A Workspace with at least one running Warren Terminal Session or retained
Workspace Editor State. Active status is a presentation fact used by the
Workspace list and does not create a new Host resource.

**Project**:
The identity of one Git repository rooted at its main checkout. A Project owns
the repository identity and the set of Git Workspaces derived from that
repository. It is metadata about the repository, not a terminal runtime.

**Terminal Group**:
A Host-owned ordered container for standalone terminal sessions that are not
bound to a Project or Workspace. The first Group is the default destination
for newly created standalone sessions. A Group may define a default startup
directory; when it does not, the Host user's home directory is used.

**Session Scope**:
The single ownership context of a Warren Terminal Session. A scope is either a
Workspace or a Terminal Group. A Session never belongs to both contexts and
never exists without one.

**Warren Terminal Session**:
A Host-owned terminal execution resource belonging to one Session Scope. It has
a durable lifecycle independent of client connectivity; ending it is an explicit
command on its sidebar entry, never a side effect of closing a view.
_Avoid_: Session

**Runtime Binding**:
The opaque association between a Warren Terminal Session and its runtime
backend. It is recovery metadata, not a second terminal resource.

**Runtime Session**:
The Ghostline PTY bound one-to-one to a Warren Terminal Session. It is an
implementation of the runtime boundary, not Warren's durable Session identity.
_Avoid_: Session

**Agent Conversation**:
A conversation owned by an external agent CLI such as Codex or Claude Code.
Warren may retain its external identifier and observed activity, but does not
own its lifecycle or equate it with a Warren Terminal Session.
_Avoid_: Codex Session, Claude Session

**Agent Activity**:
The currently observed work state of an external Agent Conversation. It is
optional and does not represent terminal lifecycle or client connectivity.

**Tab**:
A device-local window entry that references one Warren Terminal Session within a
Workspace View or Terminal Group View. Tab projection and tab order are client
model, not Host state. A Tab whose Session is rendered is a handle on that Pane,
so closing it removes the Pane from the arrangement and leaves the referenced
Session running and reachable as an ordinary Tab.

**Pane Group**:
A Host-owned whole-screen arrangement of running Warren Terminal Sessions,
belonging to exactly one Workspace or Terminal Group. The Host stores its owner,
name, order, pane tree, and revision, and projects it through the roster, so
several arrangements may coexist in one scope and any client can render them.
Editing an arrangement never creates, moves, or ends a Session.
_Avoid_: split layout, device-local layout

**Pane**:
A Host-owned leaf of a Pane Group's tree, carrying one stable Pane ID and the ID
of the one Session it renders. A Session occupies at most one Pane on a Host
across all Pane Groups. Removing a Pane edits the arrangement only and leaves
the referenced Session running.

**Active Pane Group**:
The single Pane Group a client window is currently rendering. It is per-viewer
state and is never written to the Host; background groups hold no surface, no
output subscription, and no resize authority.
_Avoid_: current pane group

**Attachment**:
A temporary client connection to a Warren Terminal Session. Disconnecting an
Attachment does not end the Session or its runtime.

**Workspace display name**:
The user-editable label shown for a Workspace. Renaming it does not rename or
checkout a Git branch and does not change the Workspace path.

**Git branch**:
The branch checked out in a Workspace's working directory. It is managed by
Git and is not changed when the Workspace display name is edited.

**Terminal display title**:
The contextual label above a terminal, rendered from a Title Template and the
Warren Terminal Session's current metadata. It does not rename the Warren
Terminal Session or Tab.
_Avoid_: Session title, Tab title

**Title Template**:
A client preference containing placeholders for Warren Terminal Session and
runtime metadata. Warren clients share its placeholder language, while each
client may keep its own preferred value.

**Warren Browser Session**:
A Warren Terminal Session whose runtime is a Chromium the Host launched rather
than a Ghostline PTY. It has the same durable lifecycle, Tab, and pane
arrangement as any other Session, and is created with `browser.session.create`
rather than `session.create`, because the terminal creation path would record a
Session that can never start. Its output is screencast frames, never PTY bytes.
_Avoid_: Browser Tab, browser window, Chrome Session

**Warren Browser**:
The Host-owned embedded Chromium runtime behind a Warren Browser Session,
together with the closed action vocabulary both the viewer page and an agent use
to drive it. The viewer page and the agent send the same normalized actions over
the same stream, so there is one input path, not two.
_Avoid_: browser-use, browser component

**Browser Viewer**:
The page the Host serves that renders one Warren Browser Session. It owns the
canvas, the stream WebSocket, and the input forwarding; the client hosts it in a
web view and owns nothing else. It is a surface, not a resource.
_Avoid_: browser pane, browser region

**Browser Frame**:
One JPEG screencast frame for a Warren Browser Session, carried on the DENB
envelope under its own kind. It is a distinct kind for the same reason
`atomicState` is one: these bytes must never reach a VT output parser, and a
browser Session has no PTY at all.

**Browser Action**:
A normalized instruction in a closed vocabulary — `navigate`, `click`, `type`,
`wait`, `snapshot`, `screenshot`, `evaluate` — sent to one Warren Browser
Session. An unknown action is a protocol error, not a passthrough.

**Warren Host**:
A running Warren Headless authority that owns Projects, Workspaces, Terminal
Sessions, and the Web interface through which those resources are accessed.

**Public Access**:
A reachability mode that lets the owner of a Warren Host access its existing
Web interface from outside the local network through a configured Relay route.
It exposes the Host to its owner; it does not grant another person access to a
Workspace.
_Avoid_: Sharing, public sharing, share link

**Sharing**:
A resource-granting mode in which a Workspace or another selected Warren
resource is made accessible to another person. Sharing is distinct from Public
Access, which is the owner's remote reachability to a Host.
_Avoid_: Public Access

**Warren Relay**:
An independently deployed control plane that authenticates Host connections,
issues scoped access capabilities, and forwards owner or Public Access routes.
It is shared infrastructure and is not a Warren Host, Workspace, or Terminal
Session.

**Relay Administrator**:
The person or organization that operates a Warren Relay as shared
infrastructure. A Relay Administrator manages Relay policy and Host
enrollment, but is not necessarily the operator of any Warren Host. Relay
Administrator authority must not be required by a Warren client after a Host
has been enrolled.

**Host Enrollment**:
The one-time act of joining a Warren Host to a Warren Relay using an
administrator-issued enrollment invitation. Enrollment establishes the
Host's durable Relay identity; the Relay Administrator's authority and
credentials are not part of the Host's client configuration.

**Host Operator**:
The person or managed device responsible for a Warren Host. A Host Operator
can make that Host reachable to Warren clients without gaining control over
the Relay deployment or other Hosts.

**Pairing Invite**:
An opaque, bearer-valued link that grants a Warren client access to one
enrolled Host for the Relay-configured sharing window. A Pairing Invite may be
used by multiple clients until it expires or the Host's pairing generation is
rotated; it is not an enrollment invitation.

**Warren Client**:
A Desktop or iOS application that consumes an enrolled Host or Pairing Invite.
A Warren Client does not administer the shared Relay control plane.

**Relay access capability**:
A short-lived signed credential issued after pairing. It authorizes a specific
Host and scope and is distinct from the Host Secret used by the daemon.

**Public Endpoint**:
The network address assigned by Relay to one enabled Host route. It identifies a
reachable route and carries no enrollment secret by itself.
