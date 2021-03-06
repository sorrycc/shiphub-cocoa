import React, { createElement as h } from 'react'
import ghost from 'util/ghost.js'
import { TimeAgo, TimeAgoString } from 'components/time-ago.js'
import CommentControls from './CommentControls.js'
import AvatarIMG from 'components/AvatarIMG.js'
import UserLink from 'components/user-link.js'

var CommentHeader = React.createClass({  
  render: function() {
    var user = this.props.comment.user||this.props.comment.author;
    if (!user) user = ghost;
    var desc = " commented ";
    if (this.props.first) {
      desc = " filed ";
    }
    if (this.props.elideAction) {
      desc = " ";
    } else if (this.props.action) {
      desc = this.props.action;
    }
    
    var pending = this.props.comment.pending_id && !this.props.comment.pending_id.startsWith("single.");
    var edited = !pending && (new Date(this.props.comment.updated_at) - new Date(this.props.comment.created_at) > 5000);
    return h('div', {className:'commentHeader'},
      h(AvatarIMG, {user:user, size:32}),
      h(UserLink, {className:'commentAuthor', user}),
      h('span', {className:'commented'}, desc),
      h(TimeAgo, {className:'commentTimeAgo', live:true, date:this.props.comment.created_at}),
      pending ? h('span', {className:'commentPending'}, 'Pending') : "",
      edited ? h('span', {className:'commentEdited', title:`Edited ${TimeAgoString(this.props.comment.updated_at)}`}, ' • edited') : "",
      h(CommentControls, this.props)
    );
  }
});

export default CommentHeader;
