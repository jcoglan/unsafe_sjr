# The security risks of RJS/SJR

37signals recently published an article on [server-generated JavaScript
responses](https://37signals.com/svn/posts/3697-server-generated-javascript-responses),
which architecturally speaking is RJS by another name. You make a request to the
server, the server returns JavaScript, and the browser runs the response through
`eval()`. This application demonstrates why using this approach for certain
kinds of requests is not safe.

## Introducing the SJR pattern

I will recap here the architectural pattern described on the 37signals blog. The
following describes the app contained in this repo, so you can run this example
yourself.

Suppose our app has two models: `User` and `Note`.

```ruby
class User < ActiveRecord::Base
  has_many :notes
end

class Note < ActiveRecord::Base
  belongs_to :user
end
```

It has some form of login mechanism, which I have built only the bare minimum
required to put a user in the session: an endpoint that, when accessed, finds a
user by name and logs them in. The fact that this controller does no real access
control is not at all a factor in the security of SJR.

```ruby
class UsersController < ApplicationController
  def login
    user = User.find_or_create_by(:username => params[:username])
    session[:user_id] = user.id
    redirect_to '/notes'
  end
end
```

To demonstrate this login mechanism, we're going to access our site via two
different hostnames. Since cookies are scoped by hostname, this will simulate
two different people accessing the site. Add these lines to your `/etc/hosts`:

```
127.0.0.1 alice
127.0.0.1 bob
```

Now start up the Rails app:

```
$ bundle --path .bundle
$ bundle exec rake db:migrate
$ bundle exec rails server
```

and visit `http://alice:3000/users/alice`. You should be redirected to
`http://alice:3000/notes`, which will tell you you're logged in as `alice`. From
this page, you can add notes -- fill in a title and body and click `Save`, and
the note will show up in your list. If you log in as another user, you get
another list; each user's note list is isolated from the others. When you
refresh the page, your notes are still there.

This is all accomplished in the `NotesController`:

```ruby
class NotesController < ApplicationController
  before_filter do
    @user = User.find_by(:id => session[:user_id])
    render(:text => 'Forbidden', :status => 403) unless @user
  end

  def index
  end

  def create
    note_params = params.require(:note).permit(:title, :body)
    @note = @user.notes.create(note_params)
  end
end
```

It checks you're logged in, displays your notes to you, and creates new notes.
The `create` action has a `js` template, which is what adds the note to the list
when you click `Save`.

```js
// app/views/notes/create.js.erb

$('#notes').append('<li><%=j @note.title %></li>');
```

This is the pattern demonstrated in the 37signals post: the combination of
`form_for(:remote => true)`, `respond_to { |f| f.js { ... } }` and a JavaScript
template. You don't actually need to use `respond_to` explicitly; Rails will
pick a template based on the request format, so just having a `.js.erb` template
for an action is enough.

## Using SJR for GET requests

Now, this example uses a POST request, but seeing this work with so little code
might tempt you into using the same pattern for GET. You decide you want to
access the user's list of notes via JavaScript, so you write something like:

```js
$.get('/notes.js', function(response) {
  eval(response);
});
```

This works because Rails sees the `.js` at the end of the URL, and dutifully
fires off `respond_to` with `format = js`, and renders a JavaScript template.
Here's ours:

```js
// app/views/notes/index.js.erb

<% @user.notes.each do |note| %>
  $('#notes').append('<li><%=j note.title %></li>');
<% end %>
```

As expected, the server retrieves the current user's notes, sends back some
JavaScript, we `eval()` it and we've got the notes on the page.

## Stealing data

Earlier, I asked you to make two aliases for `localhost`. So far we've been
accessing the site through the `alice` hostname. Now, visit
`http://bob:3000/notes`; you should see the text `Forbidden`. When going via a
different hostname, you have a different set of cookies, and since we've not
logged in on the `bob` hostname, we can't access the `Notes` controller.

So it looks like the app is doing its job of keeping unauthorized users out of
each others' private data. However, we can easily make a page that steals
Alice's data, and here it is:

```html
<!-- evil.html -->

<!doctype>
<html>
  <head>
    <meta charset="utf-8">
    <title>evil</title>
    <script src="http://code.jquery.com/jquery-1.10.2.min.js"></script>
  </head>
  <body>

    <ul id="notes"></ul>

    <script src="http://alice:3000/notes.js"></script>

  </body>
</html>
```

This page loads jQuery, sets up a container list, then injects
`http://alice:3000/notes.js`. Because this request is to the `alice` hostname,
it will send _Alice's_ cookies, and thus load and return Alice's notes. Since we
put a `.js` in the URL, Rails will use the `.js` template and send JavaScript
back, which the browser runs for us.

To see this in action, start a static file server on another port:

```
$ python -m SimpleHTTPServer 3001
```

and visit `http://bob:3001/evil.html`. Remember: we're on a different hostname,
with our own set of cookies, so we're not logged in as Alice. But despite this,
we are able to display her notes. We could even grab them directly by faking out
the jQuery API that `notes.js` talks to:

```js
var $ = function() {
  return {
    append: function(html) {
      // we just stole Alice's note titles!
    }
  };
};
```

## How does the attack work?

When you make a request, the browser looks up any cookies is holds that are
scoped to the scheme, host and path of the request's URL, and includes them in
the request. This includes requests made by `script` tags. So, when
`http://bob:3001/evil.html` includes `http://alice:3000/notes.js`, the cookies
for the `alice` hostname, which identify `alice` as the current user, are sent.

This means any site can impersonate you, simply by sending requests to a site
you are currently logged into.

Rails protects POST requests from this sort of cross-site request forgery
(CSRF) by including a special session-specific token in forms. Any POST request
not having a token that matches the current session will be rejected. Since
other sites cannot discover this token, POST requests can be trusted.

No such protection is applied to GET requests, and nor should it be. Rails will
process any GET request it receives, and will respect whatever cookies are sent
along with it.

Finally, Rails usually infers the `format` of a request from its 'extension',
defaulting to `html`. Thus, requests ending with `.js` have the `format` `js`.
But, it _also_ treats requests made with `XMLHttpRequest` (i.e. `$.get()`,
`$.post()`, etc.) as having a `format` of `js`, hence it rendering a JavaScript
template in response to our form post.

So, any site can send a `.js` request to our site, the browser will attach our
cookies, and Rails will process the request and return JavaScript. This
JavaScript runs in the context of the including page, modifying its DOM, calling
its functions, and so on. It is this side-effect-based, procedural nature of
JavaScript that lets the attacker's page include it and 'read' data from our
site, by providing its own implementations of the functions the JavaScript
calls.

## What should I do?

You can continue to use SJR for POST requests, although personally I find it an
ugly architectural style with poor separation of concerns. Rails will make sure
POST requests originate from _your_ site.

For GET requests, you should return _data, not code_. The attacker can 'read' the
response from another domain because JavaScript has side effects and modifies
global state that's visible to the attacker. Data like JSON or HTML has no side
effects and cannot be read in the same way. The only way the attack could read
the response is if you enable CORS support, _which you should never do on a site
that uses cookies for authorization_.

You should _not_ use _`respond_to` to check for XHR requests. Rails has a method
for this, it's called `request.xhr?`. `respond_to` has too broad a definition of
what a 'JavaScript' request is, and will lie to you. `request.xhr?` is based on
checking the `X-Requested-With` header, which is set by jQuery's Ajax API but
cannot be set using `script` tags.

Finally, bear in mind that this is not a problem with Rails per se. Rails takes
sensible security precautions and the above does not imply that Rails itself is
broken. The problem is that people have been encouraged to use `.js` URLs and
send JavaScript as an API response, which is dangerous. It is equally dangerous
in any other web framework; this vulnerability arises from how the web works,
and is an anti-pattern in Rails usage, rather than in the Rails codebase itself.

