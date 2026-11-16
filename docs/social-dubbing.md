# Social dubbing

The native Feed and Inbox's **Co-dubs** section use authenticated Convex functions in `convex/social.ts`. The app uses its
existing password account, Convex live client and HTTP authentication token. No messaging provider,
address-book upload or additional provider key is required.

## Setup and development

Deploy the branch's `convex/` functions and additive schema to the intended development deployment.
The app's `CONVEX_URL` and `COACH_BACKEND_URL` must refer to that same deployment's cloud and site
URLs. Source changes alone do not update a shared cloud deployment.

`users.ensure` binds a username to the verified password-account subject only when its issuer is this
deployment. Existing learners receive their username when they next sign in or restore their account;
there is no migration of existing user data. The current native app uses password sign-in. Other
identity providers need an explicit username-binding flow before they can use social features.

For isolated local development, use unused ports and run the project's existing sign-in setup against
that local deployment only. For example:

```sh
CONVEX_AGENT_MODE=anonymous npx convex dev --once --local-cloud-port 3320 --local-site-port 3321
```

There are no CI or automated QA jobs for this feature. Manual verification commands remain in the
repository README. `convex/social.test.ts` exercises the authorization, invitation and posting flow
with synthetic users and storage. `DubbingTests/SocialTests.swift` exports an actual synthetic scene
twice and spectrally checks that the first performer's voice survives the second export.

## Learner flow

Inbox retains the existing Whop **Clubs** section alongside **Co-dubs**. Invitation links select
**Co-dubs** automatically. Existing scoring, the live tutor and club challenge sharing remain available.

1. Open **Friends** from Feed or **Inbox → Co-dubs** and send a request to a Dubby username. The recipient accepts
   in their own Friends screen. A request alone grants no access to friend-only posts.
2. Finish a dub and choose **Invite a friend**. Dubby uploads the saved performance and script, then
   opens the native Messages composer with an invitation to record the other character. Choose a
   recipient and send it. Keeping at least one line is enough to invite someone; unrecorded lines
   retain the original audio. **Share your scene** offers another role or an accepted Dubby friend,
   with **Share** opening Messages. It also offers posting the solo performance to accepted friends.
   Retrying or cancelling Messages reuses the prepared invitation rather than creating another one.
3. A named friend's invitation appears in **Inbox → Co-dubs**. A link recipient opens `dubby://invite/<code>` or
   pastes its code in **Inbox → Co-dubs** after signing in. Links require the installed app; they do not provide an
   App Store fallback or anonymous web player. An open link can be claimed by one learner. A link
   addressed to a specific friend cannot be claimed by another account.
4. The recipient accepts and records the other role using the supplied script and timing. The studio
   requires every line of that role before finishing. The export is saved locally; **Finish co-dub**
   uploads its combined video and delivers it to both performers' Inboxes.
5. Each performer chooses **Post to friends feed**. Only after both approve is the combined result
   visible to accepted friends of either performer. Either performer can withdraw approval or stop
   sharing. Solo posts can be withdrawn by their author. Removing a friendship revokes feed-based
   access; it does not erase either performer's access to their own co-dubs.
6. **Swap roles and go again** starts a fresh first-role recording against the completed scene. Its
   result can create a new invitation. Existing completed performances are not overwritten.

The native Messages composer sends invitations only when the learner chooses a recipient and taps
Send. Messages must be configured on the iPhone. The operating system's share sheet remains available
for exported video and invitations in the Inbox. There is no conversational iMessage agent, automatic
message sending, general direct-message service or public feed in this implementation.

## Media and access boundaries

Social video uploads are MP4 files of at most 80 MB. The native client checks playable duration
(2–120 seconds, including whole published scenes); the backend checks storage ownership, claimed-file uniqueness, MIME type and bytes.
The script has validated roles, unique line identities, finite scene-relative timing and protected
first-performer intervals. The backend does not treat uploaded line counts as pronunciation grades.
The UI shows recorded line counts and existing local measurements; it does not invent the scores or
rankings in the reference mockup.

The first performer's saved MP4 is the second performer's source. The existing speech-band filter
suppresses the second character's original dialogue in their recording windows. The first
performer's kept audio intervals are subtracted from those suppression windows, including their
padding. Invitations reject roles whose lines overlap the kept first performance. The existing
filtering limitation remains: music/effects in the speech band sound thinner under replaced dialogue.

`/social/media/<assetId>` requires the learner's Bearer token and checks ownership, participation or
current friend-feed access before returning video with private/no-store caching. No raw storage URLs
are returned for playback. The app downloads authorized video to its temporary directory for native
playback and dubbing; downloaded or externally shared copies cannot be recalled by withdrawing a post.
Upload URLs are scoped, single-use storage capabilities; transient transfer failures get a fresh
ticket, bounded backoff and a warning. Finalization and invitation retries are idempotent.

Unpublished videos remain private to their performers on the backend. Upload records and hidden
posts are retained; account-wide erasure and orphan-upload cleanup are not implemented. Source,
recordings and user data must never be committed to the repository.

Recording quality, microphone/speech permissions, interruptions, Bluetooth routing and sharing through
Messages still need verification on an actual iPhone. Simulator renders and synthetic exports do not
verify those hardware behaviors.
