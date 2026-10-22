import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../models/household_invitation_model.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/vanity_provider.dart';
import '../../theme/app_theme.dart';
import 'household_items_section.dart';

class HouseholdScreen extends StatefulWidget {
  const HouseholdScreen({super.key});

  @override
  State<HouseholdScreen> createState() => _HouseholdScreenState();
}

class _HouseholdScreenState extends State<HouseholdScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.currentUser != null) {
        context.read<HouseholdProvider>().loadHousehold(auth.currentUser!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final householdProv = context.watch<HouseholdProvider>();
    final user = auth.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Household Sharing'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              if (user != null) {
                householdProv.loadHousehold(user);
              }
            },
          ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('Please log in'))
          : householdProv.isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.primaryRose),
                )
              : RefreshIndicator(
                  color: AppTheme.primaryRose,
                  onRefresh: () async {
                    await householdProv.loadHousehold(user);
                  },
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final err in [householdProv.errorMessage, householdProv.invitationsError])
                          if (err != null) _buildErrorBanner(err, () => householdProv.loadHousehold(user)),
                        if (user.isDemoAccount) _buildDemoModeBanner(),
                        if (householdProv.needsEmailVerification) _buildVerifyEmailBanner(context, user),
                        householdProv.hasHousehold
                            ? _buildActiveHouseholdView(context, householdProv, user)
                            : _buildNoHouseholdView(context, householdProv, user),
                      ],
                    ),
                  ),
                ),
    );
  }

  /// Banner displayed when using the offline demo account (vanity@demo.app).
  Widget _buildDemoModeBanner() {
    return Container(
      key: const ValueKey('demo-mode-household-banner'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: Color(0xFF2563EB), size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Demo mode: sign in with a real account to send invitation emails',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF1E3A8A)),
                ),
                SizedBox(height: 4),
                Text(
                  'Invitations created in demo mode are saved locally. The invitation server requires an authenticated Firebase session to email recipients.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF1E40AF)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shown to accounts whose e-mail is not verified: invitations are bound to a verified
  /// address, so they are hidden until the user verifies and refreshes.
  Widget _buildVerifyEmailBanner(BuildContext context, UserModel user) {
    return Container(
      key: const ValueKey('verify-email-banner'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.statusAmberBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.statusAmber.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.mark_email_unread_outlined, color: AppTheme.statusAmber),
              SizedBox(width: 8),
              Expanded(child: Text('Verify your e-mail to see invitations', style: TextStyle(fontWeight: FontWeight.w700))),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Household invitations are sent to an e-mail address, so we need to know ${user.email} is yours. '
            'Open the verification link we sent you, then tap "I\'ve verified my e-mail". '
            'Any invitation waiting for you stays pending until then.',
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                key: const ValueKey('resend-verification'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final error = await context.read<AuthProvider>().sendVerificationEmail();
                  messenger.showSnackBar(SnackBar(
                    content: Text(error ?? 'Verification e-mail sent to ${user.email}. Check your inbox and spam folder.'),
                  ));
                },
                child: const Text('Resend verification e-mail'),
              ),
              ElevatedButton(
                key: const ValueKey('refresh-verification'),
                onPressed: () async {
                  final auth = context.read<AuthProvider>();
                  final household = context.read<HouseholdProvider>();
                  final messenger = ScaffoldMessenger.of(context);
                  final verified = await auth.refreshEmailVerification();
                  if (verified && auth.currentUser != null) {
                    await household.loadHousehold(auth.currentUser!);
                    messenger.showSnackBar(const SnackBar(content: Text('E-mail verified. Your invitations are shown below.')));
                  } else {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('Not verified yet. Open the link in the e-mail first, then try again.'),
                    ));
                  }
                },
                child: const Text("I've verified my e-mail"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message, VoidCallback onRetry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppTheme.statusRed, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 12, color: AppTheme.textDark)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }

  // ================= VIEW WHEN IN A HOUSEHOLD =================

  Widget _buildActiveHouseholdView(
    BuildContext context,
    HouseholdProvider prov,
    UserModel user,
  ) {
    final household = prov.currentHousehold!;
    final isOwner = household.isOwner(user.userId);
    final sharedByMeCount = prov.sharedByMe(context.watch<VanityProvider>().allActiveItems).length;
    final outgoing = prov.outgoingInvitations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Household Info Header Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF8B5CF6), Color(0xFF6366F1)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      household.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isOwner ? '👑 Owner' : '👥 Member',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${household.memberUids.length} members • $sharedByMeCount shared by you • '
                '${prov.sharedWithMe.length} shared with you',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),

        // Room Code Card
        Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE9D5FF)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B5CF6).withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3E8FF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.meeting_room_rounded, size: 20, color: Color(0xFF7E22CE)),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Room Code',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                        ),
                        Text(
                          'Share code to let others join instantly',
                          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (household.roomCode.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFDDD6FE)),
                      ),
                      child: Text(
                        household.roomCode,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: Color(0xFF6D28D9),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: household.roomCode.isNotEmpty
                          ? () {
                              Clipboard.setData(ClipboardData(text: household.roomCode));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Room code copied to clipboard!'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy Code'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6D28D9),
                        side: const BorderSide(color: Color(0xFFDDD6FE)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  if (isOwner) ...[
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () => _confirmRegenerateRoomCode(context, prov, user),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Regenerate'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Actions: Invite member & Leave household
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: isOwner ? () => _showInviteDialog(context, prov, user) : null,
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: Text(isOwner ? 'Invite Member' : 'Only the owner can invite'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryRose,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _confirmLeaveHousehold(context, prov, user),
              icon: const Icon(Icons.exit_to_app_rounded, size: 18, color: AppTheme.statusRed),
              label: const Text('Leave', style: TextStyle(color: AppTheme.statusRed)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFFECACA)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // Members Section
        _buildSectionHeader('Household Members (${household.memberUids.length})'),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF1ECE8)),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: household.memberUids.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final uid = household.memberUids[index];
              final email = household.memberEmails[uid] ?? 'Member';
              final isThisOwner = household.isOwner(uid);
              final isMe = uid == user.userId;

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: isThisOwner ? const Color(0xFFF3E8FF) : const Color(0xFFF1F5F9),
                  child: Text(
                    email.isNotEmpty ? email[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isThisOwner ? const Color(0xFF7E22CE) : AppTheme.textDark,
                    ),
                  ),
                ),
                title: Text(
                  email,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                subtitle: Text(
                  isThisOwner ? 'Owner' : 'Member',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isMe)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0F2FE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('You', style: TextStyle(fontSize: 11, color: Color(0xFF0369A1))),
                      ),
                    if (isOwner && !isMe)
                      IconButton(
                        icon: const Icon(Icons.person_remove_rounded, color: AppTheme.statusRed, size: 20),
                        tooltip: 'Remove member',
                        onPressed: () => _confirmRemoveMember(context, prov, user, uid, email),
                      ),
                  ],
                ),
              );
            },
          ),
        ),

        // Outgoing Invitations
        if (outgoing.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildSectionHeader('Pending Invitations (${outgoing.length})'),
          const SizedBox(height: 10),
          ...outgoing.map((inv) => _buildOutgoingInvitationCard(context, prov, inv, user, isOwner)),
        ],

        // Products: Shared by Me / Shared with Me / Private
        const SizedBox(height: 28),
        _buildSectionHeader('Household Products'),
        const SizedBox(height: 10),
        const HouseholdItemsSection(),

        // Incoming Invitations (if any are pending to another household)
        if (prov.incomingInvitations.isNotEmpty) ...[
          const SizedBox(height: 28),
          _buildSectionHeader('Incoming Invitations (${prov.incomingInvitations.length})'),
          const SizedBox(height: 4),
          const Text(
            'You have invitations to join other households. Note that accepting an invitation requires leaving your current household first.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 10),
          ...prov.incomingInvitations.map((inv) => _buildIncomingInvitationCard(context, prov, inv, user)),
        ],
      ],
    );
  }

  // ================= VIEW WHEN NO HOUSEHOLD =================

  Widget _buildNoHouseholdView(
    BuildContext context,
    HouseholdProvider prov,
    UserModel user,
  ) {
    final incoming = prov.incomingInvitations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Intro Card
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFF1ECE8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFFF3E8FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.group_work_rounded,
                  size: 40,
                  color: Color(0xFF7E22CE),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Household Sharing',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Share selected cosmetic products with roommates, family, or partners. Avoid buying duplicate serums and share awareness of expiry dates safely and privately.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _showCreateHouseholdDialog(context, prov, user),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Create Household'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryRose,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showJoinRoomCodeDialog(context, prov, user),
                    icon: const Icon(Icons.meeting_room_rounded),
                    label: const Text('Join with Code'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF7E22CE),
                      side: const BorderSide(color: Color(0xFFD8B4FE)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),

        // Incoming Invitations
        _buildSectionHeader('Incoming Invitations (${incoming.length})'),
        const SizedBox(height: 10),

        if (incoming.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFF1ECE8)),
            ),
            child: const Center(
              child: Text(
                'No pending invitations for your email.',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
              ),
            ),
          )
        else
          ...incoming.map((inv) => _buildIncomingInvitationCard(context, prov, inv, user)),
      ],
    );
  }

  // ================= CARDS & DIALOGS =================

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppTheme.textDark,
      ),
    );
  }

  Widget _buildIncomingInvitationCard(
    BuildContext context,
    HouseholdProvider prov,
    HouseholdInvitationModel inv,
    UserModel user,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline_rounded, color: AppTheme.primaryRose, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    inv.householdName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Invited by ${inv.invitedByName.isNotEmpty ? inv.invitedByName : 'a member'}',
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              'Expires: ${DateFormat.yMMMd().format(inv.expiresAt)}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final ok = await prov.declineInvitation(inv.invitationId, user);
                      if (!ok && context.mounted && prov.errorMessage != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
                        );
                      }
                    },
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      try {
                        final success = await prov.acceptInvitation(inv.invitationId, user);
                        if (context.mounted) {
                          if (success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('🎉 Joined "${inv.householdName}"!'),
                                backgroundColor: AppTheme.statusGreen,
                              ),
                            );
                          } else if (prov.errorMessage != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
                            );
                          }
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutgoingInvitationCard(
    BuildContext context,
    HouseholdProvider prov,
    HouseholdInvitationModel inv,
    UserModel user,
    bool isOwner,
  ) {
    Color statusBgColor;
    Color statusTextColor;
    IconData statusIcon;
    String statusTooltip;

    switch (inv.emailDeliveryStatus) {
      case EmailDeliveryStatus.sent:
        statusBgColor = const Color(0xFFDCFCE7);
        statusTextColor = const Color(0xFF15803D);
        statusIcon = Icons.mark_email_read_rounded;
        statusTooltip = 'Gmail\'s SMTP server accepted the email for ${inv.invitedEmail}'
            '${inv.emailProviderResponse != null ? ' (${inv.emailProviderResponse})' : ''}. '
            'This does not guarantee Inbox placement; ask them to check Spam too.';
        break;
      case EmailDeliveryStatus.queued:
        statusBgColor = const Color(0xFFE0E7FF);
        statusTextColor = const Color(0xFF4338CA);
        statusIcon = Icons.schedule_send_rounded;
        statusTooltip = 'Email requested but not yet confirmed. Recipient can also accept directly in the app.';
        break;
      case EmailDeliveryStatus.failed:
        statusBgColor = const Color(0xFFFEE2E2);
        statusTextColor = const Color(0xFFB91C1C);
        statusIcon = Icons.error_outline_rounded;
        statusTooltip = 'Email not sent: ${inv.emailDeliveryError ?? "unknown error"}. Recipient can still accept in-app.';
        break;
      case EmailDeliveryStatus.notConfigured:
        statusBgColor = const Color(0xFFFEF3C7);
        statusTextColor = const Color(0xFFB45309);
        statusIcon = Icons.phonelink_ring_rounded;
        statusTooltip = user.isDemoAccount
            ? 'Demo mode: sign in with a real account to send invitation emails. Recipient can log in with this email to accept in-app.'
            : 'No email sent (${inv.emailDeliveryError ?? 'email sender not configured'}). '
                'Recipient can log in with this email to accept in-app.';
        break;
    }
    final canResend = inv.invitedByUid == user.userId &&
        inv.emailDeliveryStatus != EmailDeliveryStatus.sent &&
        inv.isValidPending;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFF1ECE8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    inv.invitedEmail,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                  ),
                ),
                if (isOwner)
                  TextButton(
                    onPressed: () async {
                      await prov.revokeInvitation(inv.invitationId, user);
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Revoke', style: TextStyle(color: AppTheme.statusRed, fontSize: 13)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Tooltip(
                  message: statusTooltip,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusBgColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 13, color: statusTextColor),
                        const SizedBox(width: 4),
                        Text(
                          inv.emailDeliveryStatusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: statusTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Expires ${DateFormat.MMMd().format(inv.expiresAt)}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                const Spacer(),
                if (canResend || (inv.emailDeliveryStatus == EmailDeliveryStatus.sent && inv.invitedByUid == user.userId))
                  TextButton(
                    onPressed: () => _resendEmail(context, prov, inv, user),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(canResend ? 'Retry email' : 'Resend email', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (inv.emailDeliveryStatus != EmailDeliveryStatus.sent && inv.emailDeliveryError != null) ...[
              const SizedBox(height: 6),
              Text(
                inv.emailDeliveryError!,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showCreateHouseholdDialog(BuildContext context, HouseholdProvider prov, UserModel user) {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Create Household'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Household Name',
            hintText: 'e.g. Baker St Loft, Family Vanity',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.of(ctx).pop();
              try {
                final success = await prov.createHousehold(name, user);
                if (context.mounted) {
                  if (success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('🎉 Household "$name" created!'), backgroundColor: AppTheme.statusGreen),
                    );
                  } else if (prov.errorMessage != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
                  );
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showInviteDialog(BuildContext context, HouseholdProvider prov, UserModel user) {
    final emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Invite Household Member'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the email address of the person you would like to invite. Only they will be able to accept it.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Member Email',
                hintText: 'colleague@example.com',
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'An invitation email is sent through the local invitation server (Gmail). '
                      'The recipient can also accept directly in-app after signing in with this email.',
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B), height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) return;
              Navigator.of(ctx).pop();
              try {
                final success = await prov.inviteMember(email, user);
                if (context.mounted) {
                  if (success) {
                    _showEmailOutcome(context, prov.lastSentInvitation, created: true, isDemo: user.isDemoAccount);
                  } else if (prov.errorMessage != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
                  );
                }
              }
            },
            child: const Text('Send Invite'),
          ),
        ],
      ),
    );
  }

  void _showEmailOutcome(
    BuildContext context,
    HouseholdInvitationModel? inv, {
    required bool created,
    bool isDemo = false,
  }) {
    if (inv == null) return;
    final ok = inv.emailDeliveryStatus == EmailDeliveryStatus.sent;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(invitationEmailOutcomeMessage(inv, created: created, isDemo: isDemo)),
        backgroundColor: ok ? AppTheme.statusGreen : AppTheme.statusAmber,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _resendEmail(
    BuildContext context,
    HouseholdProvider prov,
    HouseholdInvitationModel inv,
    UserModel user,
  ) async {
    final updated = await prov.resendInvitationEmail(inv.invitationId, user);
    if (!context.mounted) return;
    if (updated != null) {
      _showEmailOutcome(context, updated, created: false, isDemo: user.isDemoAccount);
    } else if (prov.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
      );
    }
  }

  Future<void> _confirmLeaveHousehold(
    BuildContext context,
    HouseholdProvider prov,
    UserModel user,
  ) async {
    final isOwner = prov.currentHousehold?.isOwner(user.userId) ?? false;
    final message = isOwner
        ? 'You are the owner. Leaving will transfer ownership or disband the household if no other members exist. All your items will be automatically unshared.'
        : 'Leaving the household will remove your access to shared items, and all your items will be automatically unshared.';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Leave Household?'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusRed),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final success = await prov.leaveHousehold(user);
        if (context.mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('You have left the household.'), backgroundColor: AppTheme.statusAmber),
            );
          } else if (prov.errorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
          );
        }
      }
    }
  }

  void _showJoinRoomCodeDialog(BuildContext context, HouseholdProvider prov, UserModel user) {
    final codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Join with Room Code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the 6-character room code (e.g. VAN-7K9P) provided by the household owner.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: codeController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Room Code',
                hintText: 'VAN-XXXX',
                prefixIcon: Icon(Icons.meeting_room_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryRose),
            onPressed: () async {
              final code = codeController.text.trim().toUpperCase();
              if (code.isEmpty) return;
              Navigator.of(ctx).pop();
              try {
                final success = await prov.joinByRoomCode(code, user);
                if (context.mounted) {
                  if (success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('🎉 Joined "${prov.currentHousehold?.name ?? 'Household'}"!'),
                        backgroundColor: AppTheme.statusGreen,
                      ),
                    );
                  } else if (prov.errorMessage != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
                  );
                }
              }
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRegenerateRoomCode(
    BuildContext context,
    HouseholdProvider prov,
    UserModel owner,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Regenerate Room Code?'),
        content: const Text(
          'The current room code will be permanently invalidated. Anyone with the old code will no longer be able to join.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7E22CE)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final newCode = await prov.regenerateRoomCode(owner);
        if (context.mounted) {
          if (newCode != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('New room code generated: $newCode'),
                backgroundColor: AppTheme.statusGreen,
              ),
            );
          } else if (prov.errorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
          );
        }
      }
    }
  }

  Future<void> _confirmRemoveMember(
    BuildContext context,
    HouseholdProvider prov,
    UserModel owner,
    String memberUid,
    String email,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove Member?'),
        content: Text(
          'Are you sure you want to remove $email from this household? '
          'Their shared items will be immediately unshared and their access will be revoked.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusRed),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final success = await prov.removeMember(memberUid, owner);
        if (context.mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$email has been removed from the household.'),
                backgroundColor: AppTheme.statusAmber,
              ),
            );
          } else if (prov.errorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: ${prov.errorMessage}'), backgroundColor: AppTheme.statusRed),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.statusRed),
          );
        }
      }
    }
  }
  }

/// Snackbar text derived from the real delivery outcome, never from the Firestore write alone.
String invitationEmailOutcomeMessage(
  HouseholdInvitationModel inv, {
  required bool created,
  bool isDemo = false,
}) {
  final prefix = created ? 'Invitation saved for ${inv.invitedEmail}. ' : '';
  if (isDemo) {
    return '${prefix}Demo mode: sign in with a real account to send invitation emails. Recipient can still accept in-app.';
  }
  switch (inv.emailDeliveryStatus) {
    case EmailDeliveryStatus.sent:
      return '${prefix}Email sent: Gmail accepted it for delivery. Ask them to check Inbox and Spam.';
    case EmailDeliveryStatus.queued:
      return '${prefix}Email requested but not yet confirmed.';
    case EmailDeliveryStatus.failed:
      return '${prefix}Email NOT sent: ${inv.emailDeliveryError ?? 'unknown error'}. They can still accept in-app.';
    case EmailDeliveryStatus.notConfigured:
      return '${prefix}No email sent: ${inv.emailDeliveryError ?? 'email sender not configured'}. They can still accept in-app.';
  }
}
