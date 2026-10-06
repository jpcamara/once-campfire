class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, SameOriginForgeryProtection, Authorization, BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
end
