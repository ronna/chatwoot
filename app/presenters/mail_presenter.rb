class MailPresenter < SimpleDelegator
  attr_accessor :mail

  def initialize(mail, account = nil)
    super(mail)
    @mail = mail
    @account = account
  end

  def

  def subject
    encode_to_unicode(@mail.subject || '')
  end

  def message_content
    @decoded_text_content = select_body(mail)
    encoding = @decoded_text_content.encoding

    body = EmailReplyTrimmer.trim(@decoded_text_content)

    # Add quoted_text logic here

    @text_content ||= {
      full: @decoded_text_content,
      reply: @decoded_text_content,
      quoted: body.force_encoding(encoding).encode("UTF-8")
    }
  end

  def select_body(message)
    if message.multipart?
      part = message.text_part || message.html_part || message
    else
      part = message
    end

    decoded = encode_to_unicode(part)

    return "" unless decoded

    # Certain trigger phrases that means we didn't parse correctly
    if decoded =~ /(Content\-Type\:|multipart\/alternative|text\/plain)/
      return ""
    end

    if (part.content_type || '').include? 'text/html'
      HTMLParser.parse_reply(decoded)
    else
      decoded
    end
  end



  # def text_content
  #   @decoded_text_content ||= encode_to_unicode(text_part&.decoded || decoded_message || '')

  #   return {} if @decoded_text_content.blank?

  #   @text_content ||= {
  #     full: @decoded_text_content,
  #     reply: extract_reply(@decoded_text_content)[:reply],
  #     quoted: extract_reply(@decoded_text_content)[:quoted_text]
  #   }
  # end

  def html_content
    @decoded_html_content ||= encode_to_unicode(html_part&.decoded)

    return {} if @decoded_html_content.blank?

    body = EmailReplyTrimmer.trim(@decoded_html_content)

    @html_content ||= {
      full: @decoded_html_content,
      reply: @decoded_html_content,
      quoted: body
    }
  end

  def attachments
    # ref : https://github.com/gorails-screencasts/action-mailbox-action-text/blob/master/app/mailboxes/posts_mailbox.rb
    mail.attachments.map do |attachment|
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(attachment.body.to_s),
        filename: attachment.filename,
        content_type: attachment.content_type
      )
      { original: attachment, blob: blob }
    end
  end

  # def decoded_message
  #   if mail.multipart?
  #     return mail.text_part ? mail.text_part.decoded : nil
  #   end

  #   mail.decoded
  # end

  def number_of_attachments
    mail.attachments.count
  end

  def serialized_data
    {
      bcc: bcc,
      cc: cc,
      content_type: content_type,
      date: date,
      from: from,
      html_content: html_content,
      in_reply_to: in_reply_to,
      message_id: message_id,
      multipart: multipart?,
      number_of_attachments: number_of_attachments,
      subject: subject,
      text_content: message_content,
      to: to
    }
  end

  def from
    # changing to downcase to avoid case mismatch while finding contact
    @mail.from.map(&:downcase)
  end

  def sender_name
    Mail::Address.new(@mail[:from].value).name
  end

  def original_sender
    @mail['X-Original-Sender'].try(:value) || from.first
  end

  def email_forwarded_for
    @mail['X-Forwarded-For'].try(:value)
  end

  def mail_receiver
    if @mail.to.blank?
      return [email_forwarded_for] if email_forwarded_for.present?

      []
    else
      @mail.to
    end
  end

  private

  # forcing the encoding of the content to UTF-8 so as to be compatible with database and serializers
  def encode_to_unicode(decoded_mail)
    return nil if decoded_mail.nil?

    if decoded_mail.charset
      decoded_mail.body.decoded.force_encoding(decoded_mail.charset.gsub(/utf8/i, "UTF-8")).encode("UTF-8").to_s
    else
      decoded_mail.body.to_s
    end
  rescue
    nil
  end

  def extract_reply(content)
    content_body = EmailReplyTrimmer.trim(content)

    {
      reply: content_body,
      quoted_text: content_body
    }
  end

  def quoted_text_regexes
    return sender_agnostic_regexes if @account.nil? || @account.support_email.blank?

    [
      Regexp.new("From:\s* #{Regexp.escape(@account.support_email)}", Regexp::IGNORECASE),
      Regexp.new("<#{Regexp.escape(@account.support_email)}>", Regexp::IGNORECASE),
      Regexp.new("#{Regexp.escape(@account.support_email)}\s+wrote:", Regexp::IGNORECASE),
      Regexp.new("On(.*)#{Regexp.escape(@account.support_email)}(.*)wrote:", Regexp::IGNORECASE)
    ] + sender_agnostic_regexes
  end

  def sender_agnostic_regexes
    @sender_agnostic_regexes ||= [
      Regexp.new("^.*On.*(\n)?wrote:$", Regexp::IGNORECASE),
      Regexp.new('^.*On(.*)(.*)wrote:$', Regexp::IGNORECASE),
      Regexp.new("-+original\s+message-+\s*$", Regexp::IGNORECASE),
      Regexp.new("from:\s*$", Regexp::IGNORECASE)
    ]
  end
end
