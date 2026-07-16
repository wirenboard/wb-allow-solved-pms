# frozen_string_literal: true

# name: wb-allow-solved-pms
# about: Re-enables Discourse Solved "accept answer" inside private messages, scoped to group inboxes (and optionally 1:1 DMs).
# version: 0.3.0
# authors: Wiren Board
# url: https://github.com/wirenboard/wb-allow-solved-pms

enabled_site_setting :solved_pm_enabled

after_initialize do
  module ::WbAllowSolvedPms
    PLUGIN_NAME = "wb-allow-solved-pms"

    # Discourse stores `type: group_list` settings as pipe-delimited group **ids** ("1|3|44").
    # Plugin versions <= 0.2.0 shipped group *names* as settings.yml defaults, so live sites
    # still hold mixed values such as "support|44|3". Both forms are accepted here.
    #
    # Do not replace this with SiteSetting.<name>_map: that is a plain split("|").map(&:to_i),
    # and "support".to_i == 0 -- group 0 is `everyone`, which would silently grant the setting
    # to the whole site.
    def self.setting_entries(value)
      value.to_s.split("|").map(&:strip).reject(&:empty?)
    end

    def self.group_ids_from_setting(value)
      entries = setting_entries(value)
      return [] if entries.empty?

      ids = entries.grep(/\A\d+\z/).map(&:to_i).select(&:positive?)
      names = entries.grep_v(/\A\d+\z/)
      ids |= ::Group.where("lower(name) IN (?)", names.map(&:downcase)).pluck(:id) if names.any?
      ids.uniq
    end

    module GuardianPatch
      # Core signature (discourse-solved 2026.4.x): `can_accept_answer?(topic, post)`, and every
      # caller passes positionally. The keyword form is tolerated too: this method is called once
      # per post by the post serializer, so an ArgumentError here would 500 whole topic pages.
      def can_accept_answer?(*args, **kwargs)
        topic = args[0] || kwargs[:topic]
        post = args[1] || kwargs[:post]

        # Not ours: hand non-PMs (and unrecognised call shapes) back to core untouched.
        return super unless topic&.private_message?

        return false unless SiteSetting.solved_enabled
        return false unless SiteSetting.solved_pm_enabled
        return false unless authenticated?
        return false unless post

        return false unless post.topic_id == topic.id
        return false unless can_see?(topic) && can_see?(post)

        # --- Guardrails: only a real, visible, human reply can become a solution ---
        return false unless post.post_type == Post.types[:regular]
        return false if post.post_number.to_i <= 1
        return false if post.whisper?
        return false if post.trashed?
        return false if topic.closed? || topic.archived?

        system_user_id = Discourse.system_user&.id
        return false if system_user_id && post.user_id == system_user_id

        return false unless wb_solved_pm_eligible_topic?(topic)

        # --- Who may mark the solution ---
        return true if is_staff?
        return true if (wb_solved_pm_setting_groups(:solved_pm_actor_groups)[:ids] &
          wb_solved_pm_user_group_ids).any?
        return true if SiteSetting.solved_pm_allow_topic_owner && topic.user_id == user.id

        false
      end

      private

      # A PM is either a *group inbox* message (at least one allowed group) or a *personal*
      # message (no allowed groups). The two are gated independently:
      #   group inbox -> solved_pm_target_groups   (empty = every group inbox is eligible)
      #   personal    -> solved_pm_allow_personal_messages (and strictly 1:1)
      def wb_solved_pm_eligible_topic?(topic)
        topic_group_ids = wb_solved_pm_topic_group_ids(topic)

        if topic_group_ids.empty?
          return false unless SiteSetting.solved_pm_allow_personal_messages
          return wb_solved_pm_one_to_one?(topic)
        end

        target = wb_solved_pm_setting_groups(:solved_pm_target_groups)
        return true unless target[:configured]

        # Configured but unresolvable => ids == [] => nothing intersects => fail closed.
        (topic_group_ids & target[:ids]).any?
      end

      # Caller has already established that the topic has no allowed groups.
      def wb_solved_pm_one_to_one?(topic)
        TopicAllowedUser.where(topic_id: topic.id).count == 2
      end

      def wb_solved_pm_topic_group_ids(topic)
        @wb_solved_pm_topic_group_ids ||= {}
        @wb_solved_pm_topic_group_ids[topic.id] ||=
          TopicAllowedGroup.where(topic_id: topic.id).pluck(:group_id)
      end

      def wb_solved_pm_user_group_ids
        @wb_solved_pm_user_group_ids ||= user.group_ids
      end

      # Resolved ids for a group_list setting, plus whether the admin configured anything at
      # all -- "not configured" and "configured but resolves to nothing" must not be conflated.
      # Memoised per Guardian (one per request) and keyed by the raw value, so a setting change
      # is never served stale.
      def wb_solved_pm_setting_groups(setting_name)
        raw = SiteSetting.public_send(setting_name).to_s
        cache = (@wb_solved_pm_setting_groups ||= {})
        cache[[setting_name, raw]] ||= begin
          entries = ::WbAllowSolvedPms.setting_entries(raw)
          ids = ::WbAllowSolvedPms.group_ids_from_setting(raw)

          if entries.any? && ids.empty?
            Rails.logger.warn(
              "[#{::WbAllowSolvedPms::PLUGIN_NAME}] SiteSetting.#{setting_name} = #{raw.inspect} " \
                "matches no existing group (expected pipe-delimited group ids). Treating it as a " \
                "misconfiguration: nothing is granted through this setting.",
            )
          end

          { configured: entries.any?, ids: ids }
        end
      end
    end
  end

  if ::Guardian.method_defined?(:can_accept_answer?)
    ::Guardian.prepend ::WbAllowSolvedPms::GuardianPatch
  else
    Rails.logger.warn("[wb-allow-solved-pms] Guardian#can_accept_answer? not found; is Solved enabled/bundled?")
  end
end
