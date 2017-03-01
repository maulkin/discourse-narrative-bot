module DiscourseNarrativeBot
  class TrackSelector
    include Actions

    GENERIC_REPLIES_COUNT_PREFIX = 'discourse-narrative-bot:track-selector-count:'.freeze

    TRACKS = [
      NewUserNarrative,
      AdvancedUserNarrative
    ]

    def initialize(input, user, post_id:, topic_id: nil)
      @input = input
      @user = user
      @post_id = post_id
      @topic_id = topic_id
      @post = Post.find_by(id: post_id)
    end

    def select
      data = DiscourseNarrativeBot::Store.get(@user.id)

      if @post && @input != :delete
        topic_id = @post.topic_id

        TRACKS.each do |klass|
          if selected_track(klass)
            klass.new.reset_bot(@user, @post)
            return
          end
        end

        if (data && data[:topic_id] == topic_id)
          state = data[:state]
          klass = (data[:track] || DiscourseNarrativeBot::NewUserNarrative.to_s).constantize

          if ((state && state.to_sym == :end) && @input == :reply)
            if bot_mentioned?(@post)
              mention_replies
            else
              generic_replies(klass::RESET_TRIGGER)
            end
          else
            klass.new.input(@input, @user, post: @post)
          end

          return
        end

        if (@input == :reply) && (bot_mentioned?(@post) || pm_to_bot?(@post) || reply_to_bot_post?(@post))
          mention_replies
        end
      elsif data && data[:state] && (data[:state] && data[:state].to_sym != :end) && @input == :delete
        klass = (data[:track] || DiscourseNarrativeBot::NewUserNarrative.to_s).constantize
        klass.new.input(@input, @user, post: @post, topic_id: @topic_id)
      end
    end

    private

    def selected_track(klass)
      return if klass.respond_to?(:can_start?) && !klass.can_start?(@user)
      bot_mentioned?(@post) && @post.raw.match(/#{klass::RESET_TRIGGER}/)
    end

    def mention_replies
      post_raw = @post.raw

      raw =
        if match_data = post_raw.match(/roll (\d+)d(\d+)/i)
          I18n.t(i18n_key('random_mention.dice'),
            results: Dice.new(match_data[1].to_i, match_data[2].to_i).roll.join(", ")
          )
        elsif match_data = post_raw.match(/show me a quote/i)
          I18n.t(i18n_key('random_mention.quote'), QuoteGenerator.generate)
        else
          discobot_username = self.class.discobot_user.username
          data = DiscourseNarrativeBot::Store.get(@user.id)

          message = I18n.t(
            i18n_key('random_mention.header'),
            discobot_username: discobot_username,
            new_user_track: NewUserNarrative::RESET_TRIGGER,
          )

          if data[:completed] && data[:completed].include?(NewUserNarrative.to_s)
            message << "\n\n#{I18n.t(i18n_key('random_mention.advanced_track'), discobot_username: discobot_username, advanced_user_track: AdvancedUserNarrative::RESET_TRIGGER)}"
          end

          message << "\n\n#{I18n.t(i18n_key('random_mention.bot_actions'), discobot_username: discobot_username)}"
        end

      fake_delay

      reply_to(@post, raw)
    end

    def generic_replies(reset_trigger)
      key = "#{GENERIC_REPLIES_COUNT_PREFIX}#{@user.id}"
      count = ($redis.get(key) || $redis.setex(key, 900, 0)).to_i

      case count
      when 0
        reply_to(@post, I18n.t(i18n_key('do_not_understand.first_response'),
          reset_trigger: reset_trigger,
          discobot_username: self.class.discobot_user.username
        ))
      when 1
        reply_to(@post, I18n.t(i18n_key('do_not_understand.second_response'),
          reset_trigger: reset_trigger,
          discobot_username: self.class.discobot_user.username
        ))
      else
        # Stay out of the user's way
      end

      $redis.incr(key)
    end

    def i18n_key(key)
      "discourse_narrative_bot.track_selector.#{key}"
    end
  end
end
